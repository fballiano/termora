//
//  AgentGateway.swift
//  Termora
//

import Combine
import Foundation
import TermoraModel
import TermoraSSH

/// Answers the `termora` command-line tool.
///
/// The gateway starts the socket service when a document unlocks and stops
/// it when the document locks, so a locked document answers nothing, not
/// even the list of names. The tool never sees a secret: a `run` reply is
/// the argv of an `ssh` command that attaches to the control master.
@MainActor
final class AgentGateway: ObservableObject {
    private let store: DocumentStore
    private let sessions: SessionsController
    private var service: AgentService?
    private var phaseWatcher: AnyCancellable?

    init(store: DocumentStore, sessions: SessionsController) {
        self.store = store
        self.sessions = sessions
        phaseWatcher = store.$phase.sink { [weak self] phase in
            if case .unlocked = phase {
                self?.start()
            } else {
                self?.stop()
            }
        }
    }

    private func start() {
        guard service == nil else { return }
        do {
            let service = try AgentService()
            service.responder = { [weak self] request in
                guard let self else { return .refused("Termora is closing.") }
                return await self.handle(request)
            }
            try service.start()
            self.service = service
        } catch {
            // The window works without the socket, so say so instead of
            // standing in the way of the unlock.
            store.errorMessage = "Termora could not open the agent socket. "
                + error.localizedDescription
        }
    }

    private func stop() {
        service?.stop()
        service = nil
    }

    // MARK: - Answering

    private func handle(_ request: AgentRequest) async -> AgentReply {
        // The service stops on lock, but a request may already be in flight.
        guard store.isUnlocked else { return .refused("The document is locked.") }
        switch request.command {
        case .list:
            return list()
        case .status:
            return status()
        case .run:
            return await run(request)
        }
    }

    private func list() -> AgentReply {
        let index = store.index
        let rows = index.document.connections
            .map { AgentBookmark(path: index.folderPath(ofParent: $0.parentID), name: $0.name) }
            .sorted { ($0.path, $0.name) < ($1.path, $1.name) }
        return AgentReply(ok: true, bookmarks: rows)
    }

    private func status() -> AgentReply {
        let rows = sessions.liveConnections.map { connection in
            AgentConnectionStatus(
                name: connection.name,
                state: describe(connection.state),
                forwards: connection.activeForwards.count
            )
        }
        return AgentReply(ok: true, connections: rows)
    }

    private func run(_ request: AgentRequest) async -> AgentReply {
        guard let name = request.bookmark, !name.isEmpty else {
            return .refused("Name a bookmark.")
        }
        guard let words = request.words, !words.isEmpty else {
            return .refused("Give a command to run.")
        }
        // `list` prints the full `path / name` form, so accept that first;
        // a bare name still works when it is unambiguous.
        let index = store.index
        let connections = index.document.connections
        let byFullName = connections.filter { fullName(of: $0) == name }
        let matches = byFullName.isEmpty ? connections.filter { $0.name == name } : byFullName
        guard let connection = matches.first else {
            return .refused("No bookmark is named \"\(name)\".")
        }
        guard matches.count == 1 else {
            return .refused(
                "\(matches.count) bookmarks are named \"\(name)\". "
                    + "Use the full name that `termora list` prints."
            )
        }
        switch await sessions.agentConnect(connection: connection) {
        case let .success(sshConnection):
            return AgentReply(ok: true, argv: sshConnection.commandArguments(words))
        case let .failure(reason):
            return .refused(reason)
        }
    }

    /// The name that `list` prints for a connection, for example
    /// `Prod / Web / web1`.
    private func fullName(of connection: Connection) -> String {
        let path = store.index.folderPath(ofParent: connection.parentID)
        return path.isEmpty ? connection.name : "\(path) / \(connection.name)"
    }

    private func describe(_ state: SSHConnection.State) -> String {
        switch state {
        case .idle: "idle"
        case .connecting: "connecting"
        case .connected: "connected"
        case .failed: "failed"
        case .disconnected: "disconnected"
        }
    }
}
