//
//  LocalCommandRunner.swift
//  TermoraSSH
//

import Foundation
import TermoraModel

/// Runs the command a connection asks for before it opens.
///
/// The command runs on this Mac, not on the far host. Royal TSX calls this a
/// task. A typical one opens a firewall for the address you call from.
public enum LocalCommandRunner {
    /// What the run produced.
    public struct Outcome: Sendable {
        public let command: LocalCommand
        public let result: CommandResult?
        /// True when the command ran longer than the limit and was stopped.
        public let timedOut: Bool

        public var succeeded: Bool { !timedOut && (result?.succeeded ?? false) }

        public var problem: String? {
            if timedOut {
                return "\(command.name) did not finish in "
                    + "\(Int(LocalCommandRunner.limit)) seconds, so Termora stopped it. "
                    + "A command that waits for an answer cannot run here."
            }
            guard let result, !result.succeeded else { return nil }
            return "\(command.name) stopped with code \(result.status). \(result.summary)"
        }
    }

    /// How long a command may run before Termora stops it.
    ///
    /// A command that asks a question has no place to ask it, so it would wait
    /// for ever. The limit turns that into a message.
    public static let limit: TimeInterval = 120

    /// Splits an argument line the way a shell does, with quotes respected.
    ///
    /// Termora does not call a shell. A shell would read the line again and
    /// give a mark such as `;` or `` ` `` a meaning that the task did not ask
    /// for, and a host name comes from a file, so it must not be able to do
    /// that.
    public static func arguments(from line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var started = false
        var quote: Character?

        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                started = true
            case " ", "\t", "\n":
                if started { result.append(current); current = ""; started = false }
            default:
                current.append(character)
                started = true
            }
        }
        if started { result.append(current) }
        return result
    }

    /// The `PATH` that your login shell uses.
    ///
    /// A program started from the Dock or from Finder inherits the small
    /// `PATH` that `launchd` sets, usually only `/usr/bin:/bin:/usr/sbin:/sbin`.
    /// A task written for a terminal expects the `PATH` of a login shell, with
    /// Homebrew and anything else you have added. Termora asks your login
    /// shell for it once.
    ///
    /// The shell is given a fixed command that holds no value from any
    /// document, so nothing a file could carry reaches it.
    static let loginPath: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }()

    /// The environment a task runs in: this one, with the login `PATH`.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let loginPath { environment["PATH"] = loginPath }
        // A task has no terminal to ask a question in, so tell it so.
        environment["TERM"] = "dumb"
        return environment
    }

    /// Finds the program named, the way a shell finds it.
    ///
    /// A Royal task may name a program without a path, such as `ping`. A
    /// `Process` needs the whole path, so Termora looks along `PATH` itself.
    static func programPath(for name: String, searching path: String?) -> String {
        guard !name.contains("/") else { return name }
        let manager = FileManager.default
        for directory in (path ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(name)"
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return name
    }

    /// Runs the command, with the `$URI$` marks filled in.
    ///
    /// - Parameter onOutput: called with each piece of output as it arrives,
    ///   so a window can show the command working instead of only a spinner.
    ///   It is called away from the main thread.
    public static func run(
        _ command: LocalCommand,
        values: CommandPlaceholders.Values,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> Outcome {
        guard !command.isEmpty else {
            return Outcome(command: command, result: nil, timedOut: false)
        }

        let named = CommandPlaceholders.resolve(command.launchPath, with: values)
            .trimmingCharacters(in: .whitespaces)
        let line = CommandPlaceholders.resolve(command.arguments, with: values)

        let environment = environment()
        let path = programPath(for: named, searching: environment["PATH"])
        let result = await ProcessRunner.run(
            path, arguments(from: line),
            environment: environment, limit: limit, onOutput: onOutput
        )

        // A command that the limit stopped reports the signal that stopped it.
        let stopped = result.status == SIGTERM || result.status == SIGKILL
        return Outcome(command: command, result: result, timedOut: stopped)
    }
}
