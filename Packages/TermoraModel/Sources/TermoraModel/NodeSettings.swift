//
//  NodeSettings.swift
//  TermoraModel
//

/// The settings that a folder can pass down and a connection can override.
///
/// A folder and a connection hold the same structure. A folder that sets a
/// value gives it to every descendant that inherits. A connection that sets a
/// value stops the search.
public struct NodeSettings: Codable, Hashable, Sendable {
    public var username: Inherited<String>
    public var authentication: Inherited<Authentication>
    /// The jump host, in `user@host` or `host` form. An empty string means
    /// no jump host.
    public var jumpHost: Inherited<String>
    public var colorTag: Inherited<ColorTag>
    public var agentForwarding: Inherited<Bool>
    public var compression: Inherited<Bool>
    /// Seconds between keep-alive messages. Zero turns keep-alive off.
    public var keepAliveSeconds: Inherited<Int>
    public var x11Forwarding: Inherited<Bool>
    public var hostKeyPolicy: Inherited<HostKeyPolicy>
    /// Text typed into the session once it opens, in the Royal TSX form,
    /// for example `cd /opt/maho/app{ENTER}`. An empty string types nothing.
    public var afterConnectText: Inherited<String>
    /// A command run on this Mac before the connection opens.
    public var beforeConnect: Inherited<LocalCommand>

    public init(
        username: Inherited<String> = .inherit,
        authentication: Inherited<Authentication> = .inherit,
        jumpHost: Inherited<String> = .inherit,
        colorTag: Inherited<ColorTag> = .inherit,
        agentForwarding: Inherited<Bool> = .inherit,
        compression: Inherited<Bool> = .inherit,
        keepAliveSeconds: Inherited<Int> = .inherit,
        x11Forwarding: Inherited<Bool> = .inherit,
        hostKeyPolicy: Inherited<HostKeyPolicy> = .inherit,
        afterConnectText: Inherited<String> = .inherit,
        beforeConnect: Inherited<LocalCommand> = .inherit
    ) {
        self.username = username
        self.authentication = authentication
        self.jumpHost = jumpHost
        self.colorTag = colorTag
        self.agentForwarding = agentForwarding
        self.compression = compression
        self.keepAliveSeconds = keepAliveSeconds
        self.x11Forwarding = x11Forwarding
        self.hostKeyPolicy = hostKeyPolicy
        self.afterConnectText = afterConnectText
        self.beforeConnect = beforeConnect
    }

    /// Every field inherits. This is the state of a new folder.
    public static let inheritAll = NodeSettings()
}

/// The settings of one connection after the search up the folder tree ends.
/// Every field has a value, so the SSH engine never has to ask again.
public struct EffectiveSettings: Hashable, Sendable {
    public var username: String
    public var authentication: Authentication
    public var jumpHost: String
    public var colorTag: ColorTag
    public var agentForwarding: Bool
    public var compression: Bool
    public var keepAliveSeconds: Int
    public var x11Forwarding: Bool
    public var hostKeyPolicy: HostKeyPolicy
    public var afterConnectText: String
    public var beforeConnect: LocalCommand

    /// The values used when no folder in the chain sets one.
    public static let fallback = EffectiveSettings(
        username: "",
        authentication: .sshConfig,
        jumpHost: "",
        colorTag: .none,
        agentForwarding: false,
        compression: false,
        keepAliveSeconds: 60,
        x11Forwarding: false,
        hostKeyPolicy: .ask,
        afterConnectText: "",
        beforeConnect: .none
    )
}

/// A colour that marks a row in the sidebar and a tab.
public enum ColorTag: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case grey
}
