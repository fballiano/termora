#!/bin/bash
# Builds Termora and starts it.
#
#   ./run.sh            build and start
#   ./run.sh --install  also copy the application to /Applications and
#                       link the `termora` command into /usr/local/bin
#
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null; then
    echo "XcodeGen is missing. Run: brew install xcodegen"
    exit 1
fi

echo "==> Making the Xcode project"
xcodegen generate >/dev/null

echo "==> Building"
xcodebuild -project Termora.xcodeproj -scheme Termora \
           -configuration Debug \
           -destination 'platform=macOS,arch=arm64' \
           -derivedDataPath build build \
    | grep -E "error:|warning:|BUILD" || true

APP="build/Build/Products/Debug/Termora.app"
if [ ! -d "$APP" ]; then
    echo "The build produced no application."
    exit 1
fi

if [ "${1:-}" = "--install" ]; then
    echo "==> Copying to /Applications"
    rm -rf "/Applications/Termora.app"
    cp -R "$APP" "/Applications/Termora.app"
    APP="/Applications/Termora.app"

    CLI="$APP/Contents/MacOS/termora-cli"
    LINK="/usr/local/bin/termora"
    if [ "$(readlink "$LINK" 2>/dev/null)" != "$CLI" ]; then
        echo "==> Linking $LINK (asks for your password)"
        sudo mkdir -p /usr/local/bin
        sudo ln -sf "$CLI" "$LINK"
    fi
fi

echo "==> Starting $APP"
# Quit an older copy first, so the new one is the one you see.
pkill -f "Termora.app/Contents/MacOS/Termora" 2>/dev/null || true
open "$APP"
