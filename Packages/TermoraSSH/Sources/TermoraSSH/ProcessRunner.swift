//
//  ProcessRunner.swift
//  TermoraSSH
//

import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let errorOutput: String

    public var succeeded: Bool { status == 0 }

    /// The line most worth showing to a person.
    ///
    /// OpenSSH writes progress notes and warnings to standard error even when
    /// everything worked, for example "Permanently added … to the list of
    /// known hosts". A warning is therefore never treated as the reason for a
    /// failure while a real message is present.
    public var summary: String {
        let lines = Self.lines(of: errorOutput).filter { !$0.hasPrefix("debug") }

        let real = lines.filter { !$0.hasPrefix("Warning:") }
        return real.last
            ?? lines.last
            ?? errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when standard error holds nothing but progress notes.
    public var isQuiet: Bool {
        Self.lines(of: errorOutput)
            .allSatisfy { $0.hasPrefix("debug") || $0.hasPrefix("Warning:") }
    }

    /// Splits output into trimmed, non-empty lines.
    ///
    /// Note the separator. OpenSSH ends its lines with a carriage return and a
    /// line feed, and Swift counts that pair as one Character. Splitting on
    /// `"\n"` therefore finds nothing and returns the whole text as a single
    /// line. `isNewline` matches the pair, and every other line ending too.
    static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public enum ProcessRunner {
    /// Runs a command and waits for it. Use it for the short `ssh -O …` calls,
    /// not for anything that produces a large amount of output.
    /// - Parameter limit: stop the command after this many seconds. A command
    ///   that waits for an answer has no place to ask for one, so without a
    ///   limit it would wait for ever. `nil` means wait as long as it takes.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        limit: TimeInterval? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }

                let outPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(
                        status: -1, output: "", errorOutput: error.localizedDescription
                    ))
                    return
                }

                // Stop a command that never finishes. `terminate` closes the
                // pipes, so the reads below end too.
                var timer: DispatchSourceTimer?
                if let limit {
                    let source = DispatchSource.makeTimerSource(queue: .global())
                    source.schedule(deadline: .now() + limit)
                    source.setEventHandler { process.terminate() }
                    source.resume()
                    timer = source
                }
                defer { timer?.cancel() }

                // Read both pipes at the same time. Reading one to its end
                // first would stop the child as soon as the other pipe fills,
                // and neither side would ever move again.
                let (outData, errorData) = readBoth(outPipe, errorPipe, onOutput)
                process.waitUntilExit()

                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    output: String(decoding: outData, as: UTF8.self),
                    errorOutput: String(decoding: errorData, as: UTF8.self)
                ))
            }
        }
    }
}

private extension ProcessRunner {
    /// Holds what one pipe produced, for a thread other than its reader.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ piece: Data) {
            lock.lock(); data.append(piece); lock.unlock()
        }

        var value: Data {
            lock.lock(); defer { lock.unlock() }; return data
        }
    }

    /// Reads both pipes to their end at the same time.
    static func readBoth(
        _ outPipe: Pipe,
        _ errorPipe: Pipe,
        _ onOutput: (@Sendable (String) -> Void)?
    ) -> (Data, Data) {
        let outBox = Box()
        let errorBox = Box()
        let group = DispatchGroup()

        for (pipe, box) in [(outPipe, outBox), (errorPipe, errorBox)] {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                while true {
                    let piece = pipe.fileHandleForReading.availableData
                    if piece.isEmpty { break }
                    box.append(piece)
                    onOutput?(String(decoding: piece, as: UTF8.self))
                }
            }
        }
        group.wait()
        return (outBox.value, errorBox.value)
    }
}

public enum POSIXQuote {
    /// Turns arguments into one command line that survives a shell.
    ///
    /// The terminal surface takes a command as one string, so a path with a
    /// space in it has to be quoted here.
    public static func line(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    public static func quote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=@,+")
        if argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
