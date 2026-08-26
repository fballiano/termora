//
//  Inherited.swift
//  TermoraModel
//

/// A setting that either has its own value or takes the value of its parent
/// folder.
///
/// Royal TSX records the same idea with a separate `…FromParent` flag next to
/// each field. One value replaces both fields, so the two can never disagree.
///
/// The JSON form is the value itself, or `null` for `.inherit`.
public enum Inherited<Value: Codable & Hashable & Sendable>: Hashable, Sendable {
    /// Take the value from the nearest ancestor that sets one.
    case inherit
    /// Use this value and stop the search.
    case value(Value)

    /// The value if this setting defines one, otherwise `nil`.
    public var ownValue: Value? {
        switch self {
        case .inherit: nil
        case let .value(value): value
        }
    }

    public var inheritsFromParent: Bool {
        self == .inherit
    }
}

extension Inherited: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .inherit
        } else {
            self = .value(try container.decode(Value.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .inherit: try container.encodeNil()
        case let .value(value): try container.encode(value)
        }
    }
}
