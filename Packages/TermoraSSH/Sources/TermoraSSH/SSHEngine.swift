//
//  SSHEngine.swift
//  TermoraSSH
//

import Foundation
import TermoraModel

/// Supplies the answers that OpenSSH asks for.
///
/// The engine never reads the document itself. It asks this object, which
/// knows where the secrets are and can put a question on screen.
@MainActor
public protocol SSHEngineDelegate: AnyObject {
    /// The secret already stored for this connection, if there is one.
    /// Return `nil` to make the engine ask the person instead.
    func storedSecret(for connectionID: UUID, prompt: AskpassPrompt) -> String?

    /// Puts the question on screen. Return `nil` to cancel the attempt.
    func askPerson(connectionID: UUID, connectionName: String, prompt: AskpassPrompt) async -> String?
}

/// Owns every live connection and the one askpass service they share.
@MainActor
public final class SSHEngine: ObservableObject {
    @Published public private(set) var connections: [UUID: SSHConnection] = [:]

    public weak var delegate: (any SSHEngineDelegate)?

    private let service: AskpassService
    private let helperPath: String
    private let controlDirectory: URL
    /// Maps an askpass token back to the connection that owns it.
    private var tokens: [String: UUID] = [:]

    /// - Parameter helperPath: the full path of `termora-askpass` inside the
    ///   application bundle.
    public init(helperPath: String) throws {
        self.helperPath = helperPath

        // Short, and inside the per-user temporary directory, because a Unix
        // socket path may not exceed 104 bytes.
        controlDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        service = try AskpassService()
        // The service holds a weak reference back, so the engine can own it
        // without the two keeping each other alive.
        service.responder = { [weak self] request in
            await self?.answer(request)
        }
        try service.start()
    }

    deinit { service.stop() }

    // MARK: - Connections

    public func connection(for id: UUID) -> SSHConnection? { connections[id] }

    /// Starts the control master for a connection, or returns the live one.
    @discardableResult
    public func connect(id: UUID, name: String, target: SSHTarget) async -> SSHConnection {
        if let existing = connections[id], existing.isConnected || existing.state == .connecting {
            return existing
        }

        let token = Self.makeToken()
        let controlPath = controlDirectory
            .appendingPathComponent("tc-\(id.uuidString.prefix(8)).sock").path

        let connection = SSHConnection(
            id: id,
            name: name,
            target: target,
            sessionToken: token,
            controlPath: controlPath,
            environment: environment(forSession: token)
        )
        tokens[token] = id
        connections[id] = connection
        await connection.connect()
        return connection
    }

    public func disconnect(id: UUID) async {
        guard let connection = connections[id] else { return }
        await connection.disconnect()
        tokens = tokens.filter { $0.value != id }
        connections[id] = nil
    }

    public func disconnectAll() async {
        for id in connections.keys { await disconnect(id: id) }
    }

    // MARK: - Answering OpenSSH

    private func answer(_ request: AskpassRequest) async -> String? {
        guard let connectionID = tokens[request.sessionToken],
              let connection = connections[connectionID]
        else {
            // An unknown token means the request did not come from a
            // connection this engine started. Refuse it.
            return nil
        }

        switch request.prompt {
        case .password, .keyPassphrase:
            if let stored = delegate?.storedSecret(for: connectionID, prompt: request.prompt),
               !stored.isEmpty {
                return stored
            }
            return await delegate?.askPerson(
                connectionID: connectionID, connectionName: connection.name, prompt: request.prompt
            )

        case .hostKey, .other:
            // A host key answer is never stored. A person decides every time.
            return await delegate?.askPerson(
                connectionID: connectionID, connectionName: connection.name, prompt: request.prompt
            )
        }
    }

    private func environment(forSession token: String) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        // Do not pass a socket that some other tool set for us.
        result.removeValue(forKey: "SSH_ASKPASS")
        for (key, value) in service.environment(forSession: token, helperPath: helperPath) {
            result[key] = value
        }
        return result
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
