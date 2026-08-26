//
//  Authentication.swift
//  TermoraModel
//

/// How Termora proves who you are to a host.
public enum Authentication: Codable, Hashable, Sendable {
    /// Use the keys held by the running `ssh-agent`.
    case agent
    /// Send a stored password when the server asks for one.
    case password(Secret)
    /// Use a private key file. The passphrase is empty when the key has none.
    case privateKey(path: String, passphrase: Secret)
    /// Let OpenSSH decide from `~/.ssh/config` and its own defaults.
    case sshConfig

    /// A short label for the inspector and the import report.
    public var kindName: String {
        switch self {
        case .agent: "Agent"
        case .password: "Password"
        case .privateKey: "Private key"
        case .sshConfig: "SSH config"
        }
    }

    /// The stored secret, if this method has one.
    public var secret: Secret? {
        switch self {
        case let .password(secret): secret
        case let .privateKey(_, passphrase): passphrase
        case .agent, .sshConfig: nil
        }
    }

    /// True when the method needs a secret but does not have one yet.
    /// The import report uses this to list entries you must complete.
    public var needsSecret: Bool {
        switch self {
        case let .password(secret): secret.isEmpty
        case .agent, .privateKey, .sshConfig: false
        }
    }
}

/// What to do when a host key is not in `known_hosts`.
public enum HostKeyPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Show the fingerprint and wait for your answer.
    case ask
    /// Refuse to connect.
    case strict
    /// Accept the key and record it.
    case acceptNew
}
