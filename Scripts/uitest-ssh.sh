#!/bin/bash
# Runs the UI tests that need a local OpenSSH server.
#
# The UI test runner may not bind a port, so the server runs out here, on a
# high port, from its own directory. Nothing touches ~/.ssh. The port and the
# key reach the tests through TEST_RUNNER_ variables, which xcodebuild copies
# into the runner's environment.
#
# Usage: ./Scripts/uitest-ssh.sh [test-target[/test-class]]
set -euo pipefail
cd "$(dirname "$0")/.."

only=${1:-TermoraUITests/TabSwitchDuringConnectTests}

dir=$(mktemp -d "${TMPDIR:-/tmp}/termora-uitest-sshd.XXXXXX")
chmod 700 "$dir"
sshd_pid=""
# Also end the ssh control masters the application leaves behind: they name
# the key path, so a match on the directory finds exactly this run's. Every
# step tolerates failure, or `set -e` stops the trap at the first dead pid.
trap '{ [ -n "$sshd_pid" ] && kill "$sshd_pid"; pkill -f "$dir"; rm -rf "$dir"; } 2>/dev/null || true' EXIT

ssh-keygen -q -t ed25519 -f "$dir/host_key" -N "" -C termora-uitest
ssh-keygen -q -t ed25519 -f "$dir/key" -N "" -C termora-uitest
cp "$dir/key.pub" "$dir/authorized_keys"
chmod 600 "$dir/authorized_keys"

port=$(( (RANDOM % 30000) + 22000 ))
cat > "$dir/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $dir/host_key
AuthorizedKeysFile $dir/authorized_keys
PidFile $dir/sshd.pid
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF

# Log to a file: children of sshd inherit stderr, and one that outlives the
# script would otherwise hold this script's output pipe open for ever.
/usr/sbin/sshd -f "$dir/sshd_config" -D -e > "$dir/sshd.log" 2>&1 &
sshd_pid=$!
for _ in $(seq 1 100); do
    nc -z 127.0.0.1 "$port" 2>/dev/null && break
    sleep 0.05
done

TEST_RUNNER_TERMORA_TEST_SSH_PORT=$port \
TEST_RUNNER_TERMORA_TEST_SSH_KEY="$dir/key" \
xcodebuild -project Termora.xcodeproj -scheme Termora \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build \
    -only-testing:"$only" test
