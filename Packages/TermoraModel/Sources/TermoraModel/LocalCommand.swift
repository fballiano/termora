//
//  LocalCommand.swift
//  TermoraModel
//

import Foundation

/// A command run on this Mac before a connection opens.
///
/// Royal TSX calls this a task. The command runs here, not on the far host:
/// a typical one opens a firewall for the address you are calling from.
public struct LocalCommand: Codable, Hashable, Sendable {
    /// The name it had in Royal TSX, shown while it runs.
    public var name: String
    /// The program to run.
    public var launchPath: String
    /// The arguments, as one line. Placeholders are replaced before it runs.
    public var arguments: String
    /// Wait for it to finish before connecting.
    public var waitsForCompletion: Bool

    public init(name: String = "", launchPath: String = "",
                arguments: String = "", waitsForCompletion: Bool = true) {
        self.name = name
        self.launchPath = launchPath
        self.arguments = arguments
        self.waitsForCompletion = waitsForCompletion
    }

    public var isEmpty: Bool {
        launchPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public static let none = LocalCommand()
}

/// Replaces the `$NAME$` marks that Royal TSX uses in a task.
public enum CommandPlaceholders {
    /// What a connection can put into a command.
    public struct Values: Hashable, Sendable {
        public var host: String
        public var port: Int
        public var username: String
        public var name: String

        public init(host: String, port: Int, username: String, name: String) {
            self.host = host
            self.port = port
            self.username = username
            self.name = name
        }
    }

    /// Marks that would put a secret on a command line.
    ///
    /// A command line is readable by every process on this Mac, so a password
    /// must never be written into one. A command that asks for this is
    /// refused, and the person is told why.
    public static let secretMarks = ["$PASSWORD$", "$PASSPHRASE$", "$CREDENTIALPASSWORD$"]

    public static func containsSecretMark(_ text: String) -> Bool {
        let upper = text.uppercased()
        return secretMarks.contains { upper.contains($0) }
    }

    public static func resolve(_ text: String, with values: Values) -> String {
        var result = text
        let table = [
            "$URI$": values.host,
            "$HOST$": values.host,
            "$HOSTNAME$": values.host,
            "$PORT$": String(values.port),
            "$USERNAME$": values.username,
            "$EFFECTIVEUSERNAME$": values.username,
            "$NAME$": values.name,
            "$CONNECTIONNAME$": values.name,
        ]
        for (mark, value) in table {
            result = result.replacingOccurrences(
                of: mark, with: value, options: .caseInsensitive
            )
        }
        return result
    }
}
