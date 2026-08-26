//
//  Secret.swift
//  TermoraModel
//

/// A password or a passphrase.
///
/// The whole document is encrypted on disk, so a secret is stored with the
/// object that uses it. This wrapper exists to stop a secret from reaching a
/// log: printing it, or putting it in a string, gives `<redacted>`.
/// Read `.value` only where the secret is actually needed.
public struct Secret: Hashable, Sendable {
    public var value: String

    public init(_ value: String) {
        self.value = value
    }

    public var isEmpty: Bool { value.isEmpty }

    public static let empty = Secret("")
}

extension Secret: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { value.isEmpty ? "<empty>" : "<redacted>" }
    public var debugDescription: String { description }
}

extension Secret: Codable {
    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
