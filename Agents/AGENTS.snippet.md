## SSH servers

Termora holds the saved SSH servers. Use `termora`, not a direct `ssh` call:
Termora already holds the host, the port, the user, the key, and the jump
host.

```bash
termora list                  # every bookmark, one per line
termora status                # every open connection
termora run web1 -- uptime    # run a command on a bookmark
```

A bookmark inside folders prints as `Prod / Web / web1`. Use that full name,
or a bare name that is unique. Put every word of the command after `--`. The
exit code of `termora run` is the exit code of the far command. Run
`termora --help` for the full contract.

Never ask for a password: Termora asks in its own window. Ask me before you
run a command that changes state on a server.
