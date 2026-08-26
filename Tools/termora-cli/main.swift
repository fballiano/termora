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

let usage = """
usage: termora list
       termora status
       termora run <bookmark> -- <command...>
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
