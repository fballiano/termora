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

    /// How long a new connection may wait for authentication before it gives
    /// up. The value is read when the connection starts, so a change applies
    /// to the next connection, not to one already opening.
    public var connectTimeout: Duration = .seconds(180)

    /// The terminal that the panes of this application draw with.
    ///
    /// Leave it `nil` when there is no terminal, for example in a test. Every
    /// connection then announces the name that all servers understand.
    public var localTerminal: LocalTerminal?

    private let service: AskpassService
    private let helperPath: String
    private let controlDirectory: URL
    /// Maps an askpass token back to the connection that owns it.
    private var tokens: [String: UUID] = [:]
    /// The servers that already hold the description of the local terminal.
    private let terminfoCache = TerminfoCache()

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
            environment: environment(forSession: token),
            readyTimeout: connectTimeout
        )
        tokens[token] = id
        connections[id] = connection
        await connection.connect()
        if connection.isConnected { await prepareTerminal(on: connection) }
        return connection
    }

    // MARK: - The terminal of the far end

    /// Decides what a pane on this connection announces as `TERM`.
    ///
    /// OpenSSH copies `TERM` into the request for the far terminal. Termora
    /// draws with Ghostty, and almost no server holds the description of
    /// `xterm-ghostty`, so `htop` and `vim` stop with "Error opening
    /// terminal". Termora therefore puts the description on the server first,
    /// over the control master that is already open. Nobody is asked for a
    /// password again, and the work happens once per server.
    ///
    /// A server that cannot take the description hears `xterm-256color`,
    /// which every server understands.
    private func prepareTerminal(on connection: SSHConnection) async {
        guard let localTerminal else { return }
        let installed = await installTerminfo(localTerminal, on: connection)
        connection.setTerminalType(installed ? localTerminal.name : RemoteTerminfo.compatibleName)
    }

    /// Returns true when the far end now understands the local terminal.
    private func installTerminfo(
        _ terminal: LocalTerminal, on connection: SSHConnection
    ) async -> Bool {
        guard let source = await RemoteTerminfo.source(of: terminal) else { return false }

        let key = "\(connection.target.destination):\(connection.target.port)"
        let fingerprint = RemoteTerminfo.fingerprint(of: source)
        if terminfoCache.holds(fingerprint, for: key) { return true }

        let result = await connection.run(
            RemoteTerminfo.installWords(for: terminal.name),
            limit: RemoteTerminfo.limit,
            input: source
        )
        // A server without `tic`, or a read-only home directory, fails here.
        // That is not an error to report: the connection simply uses the name
        // that every server understands.
        guard result.succeeded else {
            terminfoCache.forget(key)
            return false
        }
        terminfoCache.record(fingerprint, for: key)
        return true
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
