import Foundation
import Testing
@testable import TermoraModel
@testable import TermoraSSH

/// A socket path inside the per-user temporary directory, short enough for
/// a `sockaddr_un`.
private func temporarySocketPath() -> String {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ta-\(UUID().uuidString.prefix(8))/a.sock").path
}

@Test("The agent protocol carries a bookmark list back")
func agentListRoundTrip() async throws {
    let service = try AgentService(socketPath: temporarySocketPath())
    service.responder = { request in
        guard request.command == .list else { return .refused("wrong command") }
        return AgentReply(ok: true, bookmarks: [
            AgentBookmark(path: "Prod / Web", name: "web1"),
            AgentBookmark(path: "", name: "top"),
        ])
    }
    try service.start()
    defer { service.stop() }

    let path = service.socketURL.path
    let reply = await Task.detached {
        AgentClient.send(AgentRequest(command: .list), socketPath: path)
    }.value

    #expect(reply?.ok == true)
    #expect(reply?.bookmarks?.count == 2)
    #expect(reply?.bookmarks?.first?.path == "Prod / Web")
}

@Test("A run request carries awkward words across unchanged")
func agentRunCarriesWords() async throws {
    let service = try AgentService(socketPath: temporarySocketPath())
    service.responder = { request in
        // Echo the words back as the argv, so the test sees what arrived.
        AgentReply(ok: true, argv: request.words)
    }
    try service.start()
    defer { service.stop() }

    let awkward = ["echo", "a b", "it's", "läärm\n", "--", "-n"]
    let path = service.socketURL.path
    let reply = await Task.detached {
        AgentClient.send(
            AgentRequest(command: .run, bookmark: "web1", words: awkward),
            socketPath: path
        )
    }.value

    #expect(reply?.argv == awkward)
}

@Test("A refusal travels with its reason")
func agentRefusalCarriesReason() async throws {
    let service = try AgentService(socketPath: temporarySocketPath())
    service.responder = { _ in .refused("No bookmark is named \"nope\".") }
    try service.start()
    defer { service.stop() }

    let path = service.socketURL.path
    let reply = await Task.detached {
        AgentClient.send(AgentRequest(command: .run, bookmark: "nope"), socketPath: path)
    }.value

    #expect(reply?.ok == false)
    #expect(reply?.error == "No bookmark is named \"nope\".")
}

@Test("A stopped service answers nothing, like a locked document")
func agentStoppedServiceIsSilent() async throws {
    let service = try AgentService(socketPath: temporarySocketPath())
    service.responder = { _ in AgentReply(ok: true) }
    try service.start()
    service.stop()

    let path = service.socketURL.path
    let reply = await Task.detached {
        AgentClient.send(AgentRequest(command: .list), socketPath: path)
    }.value
    #expect(reply == nil)
}

@Test("A service with no responder refuses instead of hanging")
func agentNoResponderRefuses() async throws {
    let service = try AgentService(socketPath: temporarySocketPath())
    try service.start()
    defer { service.stop() }

    let path = service.socketURL.path
    let reply = await Task.detached {
        AgentClient.send(AgentRequest(command: .list), socketPath: path)
    }.value
    #expect(reply?.ok == false)
}

@Test("The default socket path fits a Unix socket address")
func agentDefaultPathIsShortEnough() {
    // A sockaddr_un holds 104 bytes of path on macOS.
    #expect(AgentSocket.defaultPath().utf8.count < 104)
}

@Test("The socket file is private to this account")
func agentSocketIsPrivate() throws {
    let service = try AgentService(socketPath: temporarySocketPath())
    try service.start()
    defer { service.stop() }

    let attributes = try FileManager.default.attributesOfItem(atPath: service.socketURL.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    let directory = service.socketURL.deletingLastPathComponent().path
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory)
    #expect((directoryAttributes[.posixPermissions] as? Int) == 0o700)
}

@MainActor
@Test("The words of a command are quoted for the far shell")
func commandArgumentsQuoteWords() {
    let connection = SSHConnection(
        id: UUID(), name: "test",
        target: SSHTarget(host: "example.test", port: 22, settings: .fallback),
        sessionToken: "token", controlPath: "/tmp/t.sock", environment: [:]
    )
    let argv = connection.commandArguments(["echo", "a b", "it's"])

    #expect(argv.first == "/usr/bin/ssh")
    #expect(argv.contains("example.test"))
    // One argument for the far shell, every word quoted where it needs it.
    #expect(argv.last == "echo 'a b' 'it'\\''s'")
}
