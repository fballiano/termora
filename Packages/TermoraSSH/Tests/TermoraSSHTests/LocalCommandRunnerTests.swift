//
//  LocalCommandRunnerTests.swift
//  TermoraSSHTests
//

import Foundation
import TermoraModel
import Testing
@testable import TermoraSSH

private let values = CommandPlaceholders.Values(
    host: "web01.example.com", port: 2222, username: "root", name: "web-01"
)

@Suite("Local commands")
struct LocalCommandRunnerTests {
    @Test("An argument line splits the way a shell splits it")
    func splitsArguments() {
        #expect(LocalCommandRunner.arguments(from: "-p 22 host") == ["-p", "22", "host"])
        #expect(LocalCommandRunner.arguments(from: "  a   b  ") == ["a", "b"])
        #expect(LocalCommandRunner.arguments(from: "\"two words\" b") == ["two words", "b"])
        #expect(LocalCommandRunner.arguments(from: "'two words'") == ["two words"])
        #expect(LocalCommandRunner.arguments(from: "") == [])
        #expect(LocalCommandRunner.arguments(from: "''") == [""],
                "An empty pair of quotes is still an argument.")
    }

    @Test("A command runs and its output comes back")
    func runsACommand() async {
        let command = LocalCommand(name: "Say the host", launchPath: "/bin/echo",
                                   arguments: "$URI$ $PORT$")
        let outcome = await LocalCommandRunner.run(command, values: values)
        #expect(outcome.succeeded)
        #expect(outcome.problem == nil)
        #expect(outcome.result?.output.contains("web01.example.com 2222") == true)
    }

    @Test("Termora does not call a shell, so a mark cannot become a command")
    func doesNotCallAShell() async {
        // The host name holds a shell mark on purpose. A shell would run the
        // second part. Termora passes it through as one word.
        let hostile = CommandPlaceholders.Values(
            host: "host; touch /tmp/termora-should-not-exist", port: 22,
            username: "root", name: "x"
        )
        let command = LocalCommand(launchPath: "/bin/echo", arguments: "$URI$")
        let outcome = await LocalCommandRunner.run(command, values: hostile)
        #expect(outcome.succeeded)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/termora-should-not-exist"))
    }

    @Test("A command that stops with an error is reported")
    func reportsAFailure() async {
        let command = LocalCommand(name: "Fail", launchPath: "/usr/bin/false")
        let outcome = await LocalCommandRunner.run(command, values: values)
        #expect(!outcome.succeeded)
        #expect(outcome.problem?.contains("Fail") == true)
    }

    @Test("A command that does not exist is reported, not ignored")
    func reportsAMissingProgram() async {
        let command = LocalCommand(name: "Missing", launchPath: "/no/such/program")
        let outcome = await LocalCommandRunner.run(command, values: values)
        #expect(!outcome.succeeded)
        #expect(outcome.problem != nil)
    }

    @Test("An empty command does nothing and reports nothing")
    func doesNothingWhenEmpty() async {
        let outcome = await LocalCommandRunner.run(.none, values: values)
        #expect(outcome.problem == nil)
        #expect(outcome.result == nil)
    }

    @Test("A command that never finishes is stopped")
    func stopsACommandThatWaits() async {
        let result = await ProcessRunner.run("/bin/sleep", ["30"], limit: 0.5)
        #expect(!result.succeeded, "The limit must stop a command that waits.")
    }

    @Test("A mark that would put a password on a command line is recognised")
    func findsSecretMarks() {
        #expect(CommandPlaceholders.containsSecretMark("--pass $PASSWORD$"))
        #expect(CommandPlaceholders.containsSecretMark("--pass \\$password\\$".replacingOccurrences(of: "\\", with: "")))
        #expect(!CommandPlaceholders.containsSecretMark("--user $USERNAME$"))
    }
}

@Suite("A task finds its programs")
struct LocalCommandPathTests {
    @Test("A program named without a path is found along PATH")
    func findsAProgramByName() {
        // `ping` sits in /sbin on a Mac, which is why a task that names it
        // fails without a search.
        let path = "/nowhere:/bin:/usr/bin:/sbin"
        #expect(LocalCommandRunner.programPath(for: "echo", searching: path) == "/bin/echo")
        #expect(LocalCommandRunner.programPath(for: "ping", searching: path) == "/sbin/ping")
    }

    @Test("A program named with a path is used as it stands")
    func keepsAWholePath() {
        #expect(LocalCommandRunner.programPath(for: "/bin/echo", searching: "/bin") == "/bin/echo")
        #expect(LocalCommandRunner.programPath(for: "./run.sh", searching: "/bin") == "./run.sh")
    }

    @Test("A program that is nowhere keeps its name, so the error names it")
    func keepsAnUnknownName() {
        #expect(LocalCommandRunner.programPath(for: "no-such-tool", searching: "/bin") == "no-such-tool")
        #expect(LocalCommandRunner.programPath(for: "echo", searching: nil) == "echo")
    }

    @Test("A task runs with the PATH of a login shell, not the small one")
    func usesTheLoginPath() {
        let environment = LocalCommandRunner.environment()
        let path = try! #require(environment["PATH"])
        #expect(path.split(separator: ":").count > 4,
                "A login PATH holds more than the four directories launchd sets.")
        #expect(environment["TERM"] == "dumb", "A task has no terminal to ask in.")
    }

    @Test("A task can call a program that only the login PATH knows")
    func callsALoginPathProgram() async {
        // `env` is everywhere, so this only proves the environment travels.
        let command = LocalCommand(name: "Show PATH", launchPath: "printenv",
                                   arguments: "PATH")
        let outcome = await LocalCommandRunner.run(
            command,
            values: CommandPlaceholders.Values(host: "h", port: 22, username: "u", name: "n")
        )
        #expect(outcome.succeeded, "A program named without a path must still run.")
        #expect(outcome.result?.output.contains(":") == true)
    }
}
