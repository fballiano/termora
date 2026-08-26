//
//  RoyalObject.swift
//  TermoraImport
//

import Foundation

/// One object read from a Royal TSX document.
///
/// A Royal document is a flat list of typed objects joined by `ParentID`, and
/// every field is a simple text element. Keeping the fields as text here means
/// the parser never has to know which fields exist, and a Royal version that
/// adds a field cannot break it.
public struct RoyalObject: Hashable, Sendable {
    /// The element name, for example `RoyalSSHConnection`.
    public let type: String
    public let fields: [String: String]

    public init(type: String, fields: [String: String]) {
        self.type = type
        self.fields = fields
    }

    public subscript(_ name: String) -> String? {
        fields[name]
    }

    public func string(_ name: String) -> String {
        fields[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Royal writes `True` and `False`.
    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        guard let raw = fields[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return fallback }
        return raw.compare("true", options: .caseInsensitive) == .orderedSame
    }

    public func int(_ name: String) -> Int? {
        fields[name].flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public var id: String { string("ID") }
    public var parentID: String { string("ParentID") }
    public var name: String { string("Name") }
}
