import Foundation
import Testing
@testable import TermoraModel
@testable import TermoraSSH

@Suite("The description of the local terminal")
struct RemoteTerminfoTests {
    @Test("A name in the database of this Mac produces source text")
    func readsADescription() async {
        let source = await RemoteTerminfo.source(of: LocalTerminal(name: "xterm-256color"))
        let text = try? #require(source)
        #expect(text?.contains("xterm-256color") == true)
    }

    @Test("A name that nothing describes produces nothing")
    func unknownNameGivesNothing() async {
        let source = await RemoteTerminfo.source(
            of: LocalTerminal(name: "no-such-terminal-4c1f")
        )
        #expect(source == nil)
    }

    @Test("The same text always gives the same fingerprint")
    func fingerprintIsStable() {
        let one = RemoteTerminfo.fingerprint(of: "abc")
        #expect(one == RemoteTerminfo.fingerprint(of: "abc"))
        #expect(one != RemoteTerminfo.fingerprint(of: "abd"))
        #expect(one.count == 16)
    }

    @Test("The install command carries the name and reads standard input")
    func installCommandShape() {
        let words = RemoteTerminfo.installWords(for: "xterm-ghostty")
        #expect(words.first == "sh")
        #expect(words.last == "", "An empty directory means the home directory.")
        let script = words[2]
        #expect(script.contains("tic -x -o \"$dir\" -"))
        #expect(script.contains("infocmp -x xterm-ghostty"))
        #expect(script.contains("${1:-$HOME/.terminfo}"))
    }

    /// The far shell reads the directory as an argument, so no character in it
    /// can become a command.
    @Test("A directory with a space or a quote stays one word")
    func directoryIsQuoted() {
        let words = RemoteTerminfo.installWords(
            for: "xterm-ghostty", directory: "/tmp/a b'; rm -rf /"
        )
        let line = POSIXQuote.line(words)
        #expect(line.hasSuffix("'/tmp/a b'\\''; rm -rf /'"))
    }

    @Test("The whole command works against a real tic")
    func installsIntoADirectory() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/tic"))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminfo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try #require(
            await RemoteTerminfo.source(of: LocalTerminal(name: "xterm-256color"))
        )
        let words = RemoteTerminfo.installWords(
            for: "xterm-256color", directory: directory.path
        )
        // Run it here as the far shell would: the words, joined into one line.
        let result = await ProcessRunner.run(
            "/bin/sh", ["-c", POSIXQuote.line(words)], limit: 20, input: source
        )

        #expect(result.succeeded, "tic failed: \(result.errorOutput)")
        // `tic` files a description under the first letter of its name.
        let written = directory.appendingPathComponent("78/xterm-256color")
        #expect(FileManager.default.fileExists(atPath: written.path))
    }
}

@Suite("The record of what each server holds")
@MainActor
struct TerminfoCacheTests {
    @Test("A server is remembered, and a new description forgets the old one")
    func remembersAndReplaces() {
        let cache = TerminfoCache(fileURL: nil)
        #expect(cache.holds("abc", for: "root@host:22") == false)

        cache.record("abc", for: "root@host:22")
        #expect(cache.holds("abc", for: "root@host:22"))
        // Another server, and another description, are not the same record.
        #expect(cache.holds("abc", for: "root@other:22") == false)
        #expect(cache.holds("def", for: "root@host:22") == false)

        cache.forget("root@host:22")
        #expect(cache.holds("abc", for: "root@host:22") == false)
    }

    @Test("The record survives a restart")
    func recordSurvivesARestart() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminfo-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        TerminfoCache(fileURL: fileURL).record("abc", for: "root@host:22")
        #expect(TerminfoCache(fileURL: fileURL).holds("abc", for: "root@host:22"))
    }
}

@Suite("Standard input of a command")
struct ProcessInputTests {
    @Test("A command reads the text it is given")
    func commandReadsItsInput() async {
        let result = await ProcessRunner.run("/bin/cat", [], limit: 10, input: "hello\n")
        #expect(result.succeeded)
        #expect(result.output == "hello\n")
    }

    @Test("A command that reads to the end of its input still returns")
    func inputPipeIsClosed() async {
        let result = await ProcessRunner.run("/usr/bin/wc", ["-c"], limit: 10, input: "abcd")
        #expect(result.succeeded)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "4")
    }
}

@Suite("The command line of a pane")
@MainActor
struct PaneCommandLineTests {
    private func connection() -> SSHConnection {
        var settings = EffectiveSettings.fallback
        settings.username = "deploy"
        return SSHConnection(
            id: UUID(), name: "web-01",
            target: SSHTarget(host: "web-01.example.com", port: 22, settings: settings),
            sessionToken: "token", controlPath: "/tmp/test.sock",
            environment: [:]
        )
    }

    @Test("A pane announces the compatible name until the engine knows better")
    func compatibleNameUntilTheEngineDecides() {
        let line = connection().terminalCommandLine()
        #expect(line.hasPrefix("/usr/bin/env TERM=xterm-256color /usr/bin/ssh "))
        #expect(line.hasSuffix("deploy@web-01.example.com"))
    }

    @Test("The name the engine chooses reaches the command line")
    func engineChoiceReachesTheCommandLine() {
        let connection = connection()
        connection.setTerminalType("xterm-ghostty")
        #expect(connection.terminalCommandLine()
            .hasPrefix("/usr/bin/env TERM=xterm-ghostty /usr/bin/ssh "))
    }
}
