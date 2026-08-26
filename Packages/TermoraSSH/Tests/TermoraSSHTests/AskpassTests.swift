import Foundation
import Testing
@testable import TermoraSSH

// The exact strings OpenSSH 10.x passes to an askpass program.
@Test("A password prompt is recognised")
func classifiesPassword() {
    #expect(AskpassPrompt.classify("root@web01's password: ") == .password)
    #expect(AskpassPrompt.classify("(root@web01) Password: ") == .password)
}

@Test("A key passphrase prompt is recognised, with the path of the key")
func classifiesPassphrase() {
    let prompt = AskpassPrompt.classify("Enter passphrase for key '/Users/fab/.ssh/id_ed25519': ")
    #expect(prompt == .keyPassphrase(keyPath: "/Users/fab/.ssh/id_ed25519"))
}

@Test("A host key question is recognised, and never treated as a password")
func classifiesHostKey() {
    let text = """
    The authenticity of host 'web01 (10.0.0.1)' can't be established.
    ED25519 key fingerprint is SHA256:abcdef.
    Are you sure you want to continue connecting (yes/no/[fingerprint])?
    """
    guard case let .hostKey(details) = AskpassPrompt.classify(text) else {
        Issue.record("A host key question must not be read as anything else.")
        return
    }
    #expect(details.contains("SHA256:abcdef"))
}

@Test("An unknown question is passed through unchanged")
func classifiesOther() {
    #expect(AskpassPrompt.classify("Enter PIN for token: ") == .other(text: "Enter PIN for token: "))
}

@Test("The helper protocol carries an answer back")
func askpassRoundTrip() async throws {
    let service = try AskpassService()
    service.responder = { request in
        request.sessionToken == "good-token" ? "the answer for \(request.rawText)" : nil
    }
    try service.start()
    defer { service.stop() }

    let path = service.socketURL.path

    let answer = await Task.detached {
        AskpassClient.ask(socketPath: path, token: "good-token", prompt: "password: ")
    }.value
    #expect(answer == "the answer for password: ")
}

@Test("A request with an unknown token gets nothing")
func askpassRefusesUnknownToken() async throws {
    let service = try AskpassService()
    service.responder = { request in
        request.sessionToken == "good-token" ? "secret" : nil
    }
    try service.start()
    defer { service.stop() }

    let path = service.socketURL.path
    let answer = await Task.detached {
        AskpassClient.ask(socketPath: path, token: "guessed-token", prompt: "password: ")
    }.value
    #expect(answer == nil)
}

@Test("A prompt with quotes and newlines survives the protocol")
func askpassCarriesAwkwardText() async throws {
    let service = try AskpassService()
    service.responder = { $0.rawText }
    try service.start()
    defer { service.stop() }

    let awkward = "line one\n\"quoted\" and 'single'\ttab: "
    let path = service.socketURL.path
    let answer = await Task.detached {
        AskpassClient.ask(socketPath: path, token: "t", prompt: awkward)
    }.value
    #expect(answer == awkward)
}

@Test("The environment forces OpenSSH to use the helper")
func askpassEnvironment() throws {
    let service = try AskpassService()
    let environment = service.environment(forSession: "token", helperPath: "/path/to/helper")

    #expect(environment["SSH_ASKPASS"] == "/path/to/helper")
    // Without this OpenSSH uses the terminal whenever it has one.
    #expect(environment["SSH_ASKPASS_REQUIRE"] == "force")
    #expect(environment["TERMORA_SESSION"] == "token")
    #expect(environment["TERMORA_AUTH_SOCK"] == service.socketURL.path)
}

@Test("The socket path fits inside a Unix socket address")
func socketPathIsShortEnough() throws {
    let service = try AskpassService()
    // A sockaddr_un holds 104 bytes of path on macOS.
    #expect(service.socketURL.path.utf8.count < 104)
}
