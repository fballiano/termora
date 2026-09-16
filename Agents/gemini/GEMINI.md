# Termora

Termora is a macOS SSH connection manager. It holds the saved servers, and
it keeps one SSH control master for each open connection. The `termora`
command asks the running application to use one of those connections.

Use `termora` instead of a direct `ssh` call. Termora already holds the
host, the port, the user, the key, and the jump host.

```bash
termora list                  # every bookmark, one per line
termora status                # every open connection
termora run web1 -- uptime    # run a command on a bookmark
```

Run `termora --help` for the full contract.

A bookmark inside folders prints as `Prod / Web / web1`. Use that full name,
or a bare name that is unique. Put every word of the command after `--`.
The exit code of `termora run` is the exit code of the far command.

Rules:

- Never ask the user for a password. Termora asks in its own window.
- Never put a secret on the command line.
- Ask the user before you run a command that changes state on a server.

Exit code 2 means that Termora is not running, that the document is locked,
or that the bookmark name is wrong. The reason is one line on standard
error.
