//
//  Document.swift
//  TermoraModel
//

import Foundation

/// One row of the bookmark tree.
public enum TreeNode: Identifiable, Hashable, Sendable {
    case folder(Folder)
    case connection(Connection)

    public var id: UUID {
        switch self {
        case let .folder(folder): folder.id
        case let .connection(connection): connection.id
        }
    }

    public var name: String {
        switch self {
        case let .folder(folder): folder.name
        case let .connection(connection): connection.name
        }
    }

    public var parentID: UUID? {
        switch self {
        case let .folder(folder): folder.parentID
        case let .connection(connection): connection.parentID
        }
    }

    public var position: Int {
        switch self {
        case let .folder(folder): folder.position
        case let .connection(connection): connection.position
        }
    }

    public var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

/// The whole bookmark tree.
///
/// Folders and connections are held in two flat lists and joined by
/// `parentID`, the same shape that a Royal TSX document uses. A flat list
/// makes a move a single field change and keeps the import direct.
public struct Document: Codable, Hashable, Sendable {
    /// Raise this number only when an older reader could misread a new file.
    public static let currentFormatVersion = 1
    /// Stops a corrupt document with a parent loop from hanging the walk.
    public static let maximumDepth = 128

    public var formatVersion: Int
    public var folders: [Folder]
    public var connections: [Connection]

    public init(
        formatVersion: Int = Document.currentFormatVersion,
        folders: [Folder] = [],
        connections: [Connection] = []
    ) {
        self.formatVersion = formatVersion
        self.folders = folders
        self.connections = connections
    }

    public static let empty = Document()

    public var isEmpty: Bool { folders.isEmpty && connections.isEmpty }

    // MARK: - Changes

    public mutating func add(_ folder: Folder) {
        folders.append(folder)
    }

    public mutating func add(_ connection: Connection) {
        connections.append(connection)
    }

    /// Removes a node. Removing a folder also removes everything inside it.
    public mutating func remove(id: UUID) {
        var doomed: Set<UUID> = [id]
        var changed = true
        var rounds = 0
        while changed, rounds < Document.maximumDepth {
            changed = false
            rounds += 1
            for folder in folders where !doomed.contains(folder.id) {
                if let parent = folder.parentID, doomed.contains(parent) {
                    doomed.insert(folder.id)
                    changed = true
                }
            }
        }
        folders.removeAll { doomed.contains($0.id) }
        connections.removeAll {
            doomed.contains($0.id) || $0.parentID.map { doomed.contains($0) } == true
        }
    }

    /// Moves a node under a new parent. The move is refused when it would put
    /// a folder inside itself.
    @discardableResult
    public mutating func move(id: UUID, toParent newParent: UUID?, position: Int) -> Bool {
        let index = DocumentIndex(self)
        if let newParent, index.isDescendant(newParent, ofOrEqualTo: id) { return false }

        if let offset = folders.firstIndex(where: { $0.id == id }) {
            folders[offset].parentID = newParent
            folders[offset].position = position
            return true
        }
        if let offset = connections.firstIndex(where: { $0.id == id }) {
            connections[offset].parentID = newParent
            connections[offset].position = position
            return true
        }
        return false
    }

    /// Moves a node to a place in a list of children.
    ///
    /// Unlike `move(id:toParent:position:)`, this names the place in the list
    /// rather than a number, and it numbers every brother again. Two nodes can
    /// therefore never end up sharing a position, which would leave the order
    /// to chance.
    @discardableResult
    public mutating func move(id: UUID, toParent newParent: UUID?, index wanted: Int) -> Bool {
        let index = DocumentIndex(self)
        if let newParent, index.isDescendant(newParent, ofOrEqualTo: id) { return false }
        guard folders.contains(where: { $0.id == id })
            || connections.contains(where: { $0.id == id }) else { return false }

        var order = index.children(of: newParent).map(\.id).filter { $0 != id }
        order.insert(id, at: max(0, min(wanted, order.count)))

        setParent(of: id, to: newParent)
        for (offset, nodeID) in order.enumerated() { setPosition(of: nodeID, to: offset) }
        return true
    }

    /// Moves a node next to, or into, another node.
    ///
    /// Returns false when the move makes no sense: a node dropped on itself, a
    /// folder dropped inside itself, or a drop into something that is not a
    /// folder.
    @discardableResult
    public mutating func move(
        id: UUID,
        relativeTo target: UUID,
        placement: DropPlacement
    ) -> Bool {
        guard id != target else { return false }
        let index = DocumentIndex(self)

        if placement == .inside {
            guard folders.contains(where: { $0.id == target }) else { return false }
            return move(id: id, toParent: target, index: .max)
        }

        guard let node = index.node(target) else { return false }
        let parent = node.parentID
        let brothers = index.children(of: parent).map(\.id).filter { $0 != id }
        guard let at = brothers.firstIndex(of: target) else { return false }
        return move(id: id, toParent: parent, index: placement == .before ? at : at + 1)
    }

    private mutating func setParent(of id: UUID, to parent: UUID?) {
        if let at = folders.firstIndex(where: { $0.id == id }) { folders[at].parentID = parent }
        if let at = connections.firstIndex(where: { $0.id == id }) { connections[at].parentID = parent }
    }

    private mutating func setPosition(of id: UUID, to position: Int) {
        if let at = folders.firstIndex(where: { $0.id == id }) { folders[at].position = position }
        if let at = connections.firstIndex(where: { $0.id == id }) { connections[at].position = position }
    }

    /// Gives the children of each parent positions 0, 1, 2 and so on.
    /// Run this after a drag, so the order stays stable when the file is saved.
    public mutating func renumberPositions() {
        let index = DocumentIndex(self)
        var parents: [UUID?] = [nil]
        parents.append(contentsOf: folders.map { Optional($0.id) })

        for parent in parents {
            for (offset, node) in index.children(of: parent).enumerated() {
                switch node {
                case let .folder(folder):
                    if let at = folders.firstIndex(where: { $0.id == folder.id }) {
                        folders[at].position = offset
                    }
                case let .connection(connection):
                    if let at = connections.firstIndex(where: { $0.id == connection.id }) {
                        connections[at].position = offset
                    }
                }
            }
        }
    }
}
