//
//  Nodes.swift
//  TermoraModel
//

import Foundation

/// A folder in the bookmark tree.
public struct Folder: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// The parent folder. `nil` puts the folder at the top level.
    public var parentID: UUID?
    public var name: String
    /// The order among the children of the same parent. Lower comes first.
    public var position: Int
    public var isExpanded: Bool
    public var settings: NodeSettings
    public var notes: String

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        name: String,
        position: Int = 0,
        isExpanded: Bool = true,
        settings: NodeSettings = .inheritAll,
        notes: String = ""
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.position = position
        self.isExpanded = isExpanded
        self.settings = settings
        self.notes = notes
    }
}

/// One SSH bookmark.
public struct Connection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var parentID: UUID?
    public var name: String
    public var position: Int
    /// The host name or the address. This is never inherited.
    public var host: String
    /// The TCP port. This is never inherited.
    public var port: Int
    public var isFavorite: Bool
    public var settings: NodeSettings
    public var forwards: [PortForward]
    public var notes: String

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        name: String,
        position: Int = 0,
        host: String,
        port: Int = 22,
        isFavorite: Bool = false,
        settings: NodeSettings = .inheritAll,
        forwards: [PortForward] = [],
        notes: String = ""
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.position = position
        self.host = host
        self.port = port
        self.isFavorite = isFavorite
        self.settings = settings
        self.forwards = forwards
        self.notes = notes
    }
}

/// One tunnel carried by a connection.
public struct PortForward: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// Listen on this machine and send to the remote side.
        case local
        /// Listen on the remote side and send to this machine.
        case remote
        /// Listen on this machine as a SOCKS proxy.
        case dynamic
    }

    public var id: UUID
    public var kind: Kind
    public var isEnabled: Bool
    /// The address the listener binds to. An empty string means `localhost`.
    public var bindAddress: String
    public var listenPort: Int
    /// The far end of the tunnel. A dynamic tunnel ignores both fields.
    public var destinationHost: String
    public var destinationPort: Int

    public init(
        id: UUID = UUID(),
        kind: Kind,
        isEnabled: Bool = true,
        bindAddress: String = "",
        listenPort: Int,
        destinationHost: String = "",
        destinationPort: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.bindAddress = bindAddress
        self.listenPort = listenPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }

    /// A dynamic tunnel is a SOCKS proxy, so it has no far end.
    public var usesDestination: Bool { kind != .dynamic }

    /// The address the listener binds to, with the default filled in.
    public var effectiveBindAddress: String {
        bindAddress.isEmpty ? "localhost" : bindAddress
    }

    /// One line for the inspector, for example `8080 → localhost:80`.
    public var summary: String {
        switch kind {
        case .local:
            "\(effectiveBindAddress):\(listenPort) → \(destinationHost):\(destinationPort)"
        case .remote:
            "remote \(effectiveBindAddress):\(listenPort) → \(destinationHost):\(destinationPort)"
        case .dynamic:
            "SOCKS on \(effectiveBindAddress):\(listenPort)"
        }
    }

    /// Why this tunnel cannot be used, or `nil` when it is ready.
    ///
    /// The interface shows this next to the row, so a tunnel that OpenSSH
    /// would refuse is caught before you connect rather than after.
    public var problem: String? {
        guard PortForward.isValidPort(listenPort) else {
            return "The listening port must be between 1 and 65535."
        }
        guard usesDestination else { return nil }
        if destinationHost.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Give the address of the far end."
        }
        guard PortForward.isValidPort(destinationPort) else {
            return "The port of the far end must be between 1 and 65535."
        }
        return nil
    }

    public var isReady: Bool { problem == nil }

    public static func isValidPort(_ value: Int) -> Bool {
        (1 ... 65535).contains(value)
    }
}

public extension Connection {
    /// Tunnels that share a listening port, which OpenSSH would refuse.
    ///
    /// Two tunnels on one port cannot both listen. The check ignores the far
    /// end, because the listener is what collides.
    var clashingForwardIDs: Set<UUID> {
        var seen: [String: [UUID]] = [:]
        for forward in forwards where forward.isEnabled {
            let key = "\(forward.kind == .remote ? "remote" : "local")"
                + "|\(forward.effectiveBindAddress)|\(forward.listenPort)"
            seen[key, default: []].append(forward.id)
        }
        return Set(seen.values.filter { $0.count > 1 }.flatMap { $0 })
    }
}
