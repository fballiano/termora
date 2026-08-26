//
//  ImportReport.swift
//  TermoraImport
//

import Foundation

/// What the import did, and what it could not do.
///
/// Every entry that lost something appears here. An import must never drop a
/// setting quietly.
public struct ImportReport: Hashable, Sendable {
    public struct Note: Hashable, Sendable, Identifiable {
        public var id: String { "\(connectionName)|\(text)" }
        public let connectionName: String
        public let text: String
    }

    public var foldersCreated: Int = 0
    public var connectionsCreated: Int = 0

    /// Entries Termora did not import at all, with the reason.
    public var skipped: [Note] = []
    /// Entries that need a secret you must type in.
    public var missingSecrets: [Note] = []
    /// Settings that Termora does not hold, listed so nothing is lost silently.
    public var notImported: [Note] = []
    /// Secrets that Royal TSX handed over.
    public var secretsRecovered: Int = 0

    public var hasProblems: Bool {
        !skipped.isEmpty || !missingSecrets.isEmpty || !notImported.isEmpty
    }

    public var summary: String {
        var parts = ["\(connectionsCreated) connections", "\(foldersCreated) folders"]
        if secretsRecovered > 0 { parts.append("\(secretsRecovered) secrets") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        return parts.joined(separator: ", ")
    }

    mutating func skip(_ name: String, _ reason: String) {
        skipped.append(Note(connectionName: name, text: reason))
    }

    mutating func needsSecret(_ name: String, _ reason: String) {
        missingSecrets.append(Note(connectionName: name, text: reason))
    }

    mutating func note(_ name: String, _ text: String) {
        notImported.append(Note(connectionName: name, text: text))
    }
}
