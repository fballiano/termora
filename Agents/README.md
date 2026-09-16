# Agent integrations

Each folder here teaches one AI agent to drive Termora with the bundled
`termora` command. Every file is plain text. None of them holds a secret,
and none of them changes how Termora works.

The command itself is the contract. Run `termora --help` to read it. An
agent that reads help needs nothing from this folder.

| Path | Agent | How the user installs it |
|---|---|---|
| `../plugins/termora` | Claude Code | `/plugin marketplace add fballiano/termora`, then `/plugin install termora@termora` |
| `AGENTS.snippet.md` | Codex, Amp, Zed, and others | Paste the block into the project `AGENTS.md`, or into `~/.codex/AGENTS.md` |
| `gemini/GEMINI.md` | Gemini CLI | `gemini extensions install https://github.com/fballiano/termora` |
| `cursor/termora.mdc` | Cursor | Copy the file into `.cursor/rules/` or into `~/.cursor/rules/` |

Cursor reads `AGENTS.md` too. The rule file is better: it carries a
description, so Cursor loads the text only when the work needs a server.

## Permission

An agent runs `termora` through its shell tool. Most agents block a new
command until the user allows it. In Claude Code the permission is
`Bash(termora:*)`. Each agent names it differently, so read the agent's own
documentation.

## Keep the files together

The four texts say the same thing in four formats. When the command changes,
change `Tools/termora-cli/main.swift` first, then every file here.

The Gemini manifest is `gemini-extension.json`, in the root of the
repository. The Gemini CLI reads the manifest from the root of the folder
that it clones, so the file cannot move into this folder. Its
`contextFileName` points back here, so the repository holds no `GEMINI.md`
of its own.
