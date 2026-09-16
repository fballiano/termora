//
//  main.swift
//  termora-cli
//
//  The `termora` command-line tool, for scripts and AI agents. It holds no
//  secret and reads no document. It sends one JSON request to the running
//  application over a private Unix socket, and the application does the
//  rest. For `run`, the reply carries the argv of an `ssh` command that
//  attaches to the already authenticated control master; this tool executes
//  that argv, so output streams through and the far exit code comes back.
//
//  Exit codes: 0 success; 2 the application is not running, the document is
//  locked, or the request was refused. `run` exits with the far command's
//  own code.
//
//  The protocol lives in AgentProtocol.swift, which this target compiles
//  together with this file.
//

import Foundation

/// The short form. A wrong verb prints this, so an agent reads three lines
/// and one pointer rather than a page.
let usage = """
usage: termora list
       termora status
       termora run <bookmark> -- <command...>

Run `termora --help` for the whole contract.
"""

/// The whole contract, for a person or an agent that asks for it.
let helpText = """
usage: termora list
       termora status
       termora run <bookmark> -- <command...>

Termora keeps the SSH connections. This tool asks the running application
to use one. It holds no password and it reads no document.

  list    Prints every bookmark, one per line, sorted.
          A bookmark inside folders prints as "Prod / Web / web1".

  status  Prints one line for each open connection:
          name, a tab, the state, a tab, the number of tunnels.
          The state is idle, connecting, connected, failed, or disconnected.

  run     Runs a command on a bookmark and streams the output.
          Give the full name that `list` prints, or a bare name that is
          unique. Put every word of the command after `--`.
          Termora opens the connection when it is closed.

Examples:
  termora run web1 -- uptime
  termora run "Prod / Web / web1" -- systemctl is-active nginx

Exit codes:
  0   The request succeeded.
  2   Termora is not running, the document is locked, or the request
      was refused. The reason is one line on standard error.
  *   `run` exits with the exit code of the far command.

Termora asks you for a password or a passphrase in its own window. The
password never reaches this tool, the command line, or the environment.
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// Sends one request. Every failure ends the tool with code 2.
func reply(for request: AgentRequest) -> AgentReply {
    guard let reply = AgentClient.send(request, socketPath: AgentSocket.defaultPath()) else {
        fail("Termora is not running, or the document is locked.", code: 2)
    }
    guard reply.ok else {
        fail(reply.error ?? "Termora refused the request.", code: 2)
    }
    return reply
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "help", "--help", "-h":
    // An agent reads `--help` before it uses an unknown command, so the
    // text goes to standard output and the tool succeeds.
    print(helpText)
    exit(0)

case "list":
    for row in reply(for: AgentRequest(command: .list)).bookmarks ?? [] {
        print(row.path.isEmpty ? row.name : "\(row.path) / \(row.name)")
    }

case "status":
    for row in reply(for: AgentRequest(command: .status)).connections ?? [] {
        print("\(row.name)\t\(row.state)\t\(row.forwards)")
    }

case "run":
    // The words after `--` go across as separate words, so nothing here has
    // to guess at quoting. The application quotes them for the far shell.
    guard arguments.count >= 4, arguments[2] == "--" else {
        fail(usage, code: 2)
    }
    let answer = reply(for: AgentRequest(
        command: .run, bookmark: arguments[1], words: Array(arguments.dropFirst(3))
    ))
    guard let argv = answer.argv, let executable = argv.first else {
        fail("Termora sent no command back.", code: 2)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(argv.dropFirst())
    // Standard input, output, and error stay inherited, so the far command
    // streams into this terminal and can even be interactive.
    do {
        try process.run()
    } catch {
        fail("Could not start ssh. \(error.localizedDescription)", code: 2)
    }
    process.waitUntilExit()
    exit(process.terminationStatus)

default:
    fail(usage, code: 2)
}
