//
//  DocumentIndex.swift
//  TermoraModel
//

import Foundation

/// A read-only view of a document that answers tree questions quickly.
///
/// Build one after each change and keep it while you draw the sidebar or
/// start a connection. Every walk up the tree stops after
/// `Document.maximumDepth` steps, so a document with a parent loop returns a
/// wrong answer instead of hanging.
public struct DocumentIndex: Sendable {
    public let document: Document
    private let foldersByID: [UUID: Folder]
    private let childFolders: [UUID?: [Folder]]
    private let childConnections: [UUID?: [Connection]]

    public init(_ document: Document) {
        self.document = document
        foldersByID = Dictionary(document.folders.map { ($0.id, $0) }) { first, _ in first }
        childFolders = Dictionary(grouping: document.folders, by: \.parentID)
        childConnections = Dictionary(grouping: document.connections, by: \.parentID)
    }

    // MARK: - Tree

    public func folder(_ id: UUID) -> Folder? { foldersByID[id] }

    public func connection(_ id: UUID) -> Connection? {
        document.connections.first { $0.id == id }
    }

    /// The children of one parent, folders first, then by position, then by name.
    /// The folder or the connection with this identifier.
    public func node(_ id: UUID) -> TreeNode? {
        if let folder = folder(id) { return .folder(folder) }
        if let connection = connection(id) { return .connection(connection) }
        return nil
    }

    public func children(of parentID: UUID?) -> [TreeNode] {
        let nodes = (childFolders[parentID] ?? []).map(TreeNode.folder)
            + (childConnections[parentID] ?? []).map(TreeNode.connection)
        // Order by position alone. A rule that put every folder first would
        // make it impossible to drag a folder below a bookmark: the drop
        // would work, and the folder would jump back to the head of the list.
        return nodes.sorted { left, right in
            if left.position != right.position { return left.position < right.position }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// The folders above a node, nearest parent first.
    /// How many folders and bookmarks sit inside a folder, at any depth.
    ///
    /// Deleting a folder deletes all of them, so a person must be told the
    /// number before it happens.
    public func contents(of folderID: UUID) -> (folders: Int, connections: Int) {
        var folders = 0
        var connections = 0
        var toVisit = [folderID]
        var visited: Set<UUID> = []

        while let next = toVisit.popLast() {
            guard visited.insert(next).inserted else { continue }
            for child in children(of: next) {
                switch child {
                case let .folder(folder):
                    folders += 1
                    toVisit.append(folder.id)
                case .connection:
                    connections += 1
                }
            }
        }
        return (folders, connections)
    }

    public func ancestors(ofParent parentID: UUID?) -> [Folder] {
        var result: [Folder] = []
        var current = parentID
        var steps = 0
        while let id = current, steps < Document.maximumDepth {
            guard let folder = foldersByID[id] else { break }
            result.append(folder)
            current = folder.parentID
            steps += 1
        }
        return result
    }

    /// The folder path of a node, for example `Prod / Web`.
    public func folderPath(ofParent parentID: UUID?, separator: String = " / ") -> String {
        ancestors(ofParent: parentID).reversed().map(\.name).joined(separator: separator)
    }

    /// True when `candidate` is `ancestor`, or sits inside it.
    /// `move` uses this to refuse putting a folder inside itself.
    public func isDescendant(_ candidate: UUID, ofOrEqualTo ancestor: UUID) -> Bool {
        if candidate == ancestor { return true }
        var current = foldersByID[candidate]?.parentID
        var steps = 0
        while let id = current, steps < Document.maximumDepth {
            if id == ancestor { return true }
            current = foldersByID[id]?.parentID
            steps += 1
        }
        return false
    }

    // MARK: - Inheritance

    /// Resolves every setting of a connection against its folder chain.
    ///
    /// For each field the search starts at the connection. The first node that
    /// sets a value wins. When no node in the chain sets one, `fallback`
    /// supplies it. The application passes its own fallback here, so a person
    /// can choose the defaults without touching any document.
    public func effectiveSettings(
        for connection: Connection,
        fallback: EffectiveSettings = .fallback
    ) -> EffectiveSettings {
        effectiveSettings(of: connection.settings, under: connection.parentID, fallback: fallback)
    }

    /// The same search for a folder. The inspector uses it to show a folder
    /// what it would pass down.
    public func effectiveSettings(
        for folder: Folder,
        fallback: EffectiveSettings = .fallback
    ) -> EffectiveSettings {
        effectiveSettings(of: folder.settings, under: folder.parentID, fallback: fallback)
    }

    /// The search itself: start at `settings`, then walk up from `parentID`.
    public func effectiveSettings(
        of settings: NodeSettings,
        under parentID: UUID?,
        fallback: EffectiveSettings = .fallback
    ) -> EffectiveSettings {
        EffectiveSettings(
            username: resolve(\.username, settings, parentID, fallback.username),
            authentication: resolve(\.authentication, settings, parentID, fallback.authentication),
            jumpHost: resolve(\.jumpHost, settings, parentID, fallback.jumpHost),
            colorTag: resolve(\.colorTag, settings, parentID, fallback.colorTag),
            agentForwarding: resolve(\.agentForwarding, settings, parentID, fallback.agentForwarding),
            compression: resolve(\.compression, settings, parentID, fallback.compression),
            keepAliveSeconds: resolve(\.keepAliveSeconds, settings, parentID, fallback.keepAliveSeconds),
            x11Forwarding: resolve(\.x11Forwarding, settings, parentID, fallback.x11Forwarding),
            hostKeyPolicy: resolve(\.hostKeyPolicy, settings, parentID, fallback.hostKeyPolicy),
            afterConnectText: resolve(\.afterConnectText, settings, parentID,
                                      fallback.afterConnectText),
            beforeConnect: resolve(\.beforeConnect, settings, parentID, fallback.beforeConnect)
        )
    }

    /// The folder that supplies one inherited field, or `nil` when the
    /// connection sets it or nothing does. The inspector shows this name next
    /// to an inherited field.
    public func sourceFolder<Value>(
        of keyPath: KeyPath<NodeSettings, Inherited<Value>>,
        for connection: Connection
    ) -> Folder? {
        sourceFolder(of: keyPath, in: connection.settings, under: connection.parentID)
    }

    public func sourceFolder<Value>(
        of keyPath: KeyPath<NodeSettings, Inherited<Value>>,
        for folder: Folder
    ) -> Folder? {
        sourceFolder(of: keyPath, in: folder.settings, under: folder.parentID)
    }

    public func sourceFolder<Value>(
        of keyPath: KeyPath<NodeSettings, Inherited<Value>>,
        in settings: NodeSettings,
        under parentID: UUID?
    ) -> Folder? {
        guard settings[keyPath: keyPath].inheritsFromParent else { return nil }
        for folder in ancestors(ofParent: parentID)
        where folder.settings[keyPath: keyPath].ownValue != nil {
            return folder
        }
        return nil
    }

    private func resolve<Value>(
        _ keyPath: KeyPath<NodeSettings, Inherited<Value>>,
        _ settings: NodeSettings,
        _ parentID: UUID?,
        _ fallback: Value
    ) -> Value {
        if let own = settings[keyPath: keyPath].ownValue { return own }
        for folder in ancestors(ofParent: parentID) {
            if let value = folder.settings[keyPath: keyPath].ownValue { return value }
        }
        return fallback
    }
}
