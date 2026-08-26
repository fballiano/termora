//
//  DocumentStore.swift
//  Termora
//

import Foundation
import SwiftUI
import TermoraModel
import TermoraVault

/// Holds the open document and the state of the sidebar.
///
/// Every change goes through `update`, so the index that the sidebar reads is
/// rebuilt exactly once per change, and the file is saved on the same path.
@MainActor
final class DocumentStore: ObservableObject {
    enum Phase: Equatable {
        /// No document has been chosen yet.
        case welcome
        /// A document is known but still closed.
        case locked(URL)
        /// A document is open.
        case unlocked
    }

    @Published private(set) var phase: Phase = .welcome
    @Published private(set) var index = DocumentIndex(.empty)
    @Published private(set) var documentURL: URL?
    @Published var selection: UUID?
    @Published var filterText: String = ""
    @Published var errorMessage: String?
    /// A problem with unlocking. The unlock screen shows it under the field,
    /// so no alert has to interrupt the next attempt.
    @Published var unlockErrorMessage: String?
    /// Documents that were open before, newest first.
    @Published private(set) var recentDocumentURLs: [URL] = []
    /// The folder or connection being edited in the sheet, if any.
    @Published var editingID: UUID?
    /// The node a person has asked to delete. The sidebar asks before it goes.
    @Published var deletingID: UUID?

    private var vault: Vault?

    private static let lastDocumentKey = "TermoraLastDocumentPath"
    private static let recentDocumentsKey = "TermoraRecentDocumentPaths"
    private static let recentDocumentsLimit = 5

    init() {
        recentDocumentURLs = (UserDefaults.standard
            .stringArray(forKey: Self.recentDocumentsKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        if AppSettings.opensLastDocumentAtLaunch,
           let path = UserDefaults.standard.string(forKey: Self.lastDocumentKey),
           FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            documentURL = url
            phase = .locked(url)
        }
    }

    /// Puts a document at the top of the recent list.
    private func rememberRecent(_ url: URL) {
        var recents = recentDocumentURLs.filter { $0.path != url.path }
        recents.insert(url, at: 0)
        if recents.count > Self.recentDocumentsLimit {
            recents.removeLast(recents.count - Self.recentDocumentsLimit)
        }
        recentDocumentURLs = recents
        UserDefaults.standard.set(recents.map(\.path), forKey: Self.recentDocumentsKey)
    }

    // MARK: - Opening

    func create(at url: URL, password: String) async {
        do {
            let vault = try await Vault.create(at: url, password: password)
            adopt(vault)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(at url: URL, password: String, rememberWithTouchID: Bool) async {
        do {
            let vault = try await Vault.open(at: url, password: password)
            if rememberWithTouchID {
                let material = vault.keyMaterial
                // Say so when it fails. A quiet failure looks exactly like
                // success until the next launch asks for the password again.
                if let problem = VaultKeyStore.store(
                    key: material.key, salt: material.salt, for: url
                ) {
                    errorMessage = "The document is open, but Termora could not "
                        + "remember it for Touch ID. \(problem)"
                }
            }
            adopt(vault)
        } catch {
            // Under the field, not in an alert. An alert takes a click before
            // the next attempt, and steals the focus from the field.
            unlockErrorMessage = error.localizedDescription
        }
    }

    /// Opens with the key held in the Keychain. macOS asks for Touch ID.
    func openWithStoredKey(at url: URL) async {
        do {
            let header = try Vault.inspect(at: url)
            let outcome = VaultKeyStore.loadKey(
                salt: header.kdf.salt,
                for: url,
                reason: "unlock your Termora document"
            )
            switch outcome {
            case let .key(key):
                adopt(try Vault.open(at: url, key: key))
            case .noRecord:
                unlockErrorMessage = "Termora remembers no key for this document. "
                    + "Use the master password."
            case let .failed(problem):
                unlockErrorMessage = problem
            }
        } catch {
            unlockErrorMessage = error.localizedDescription
        }
    }

    /// True when this document has a key waiting behind Touch ID.
    func hasStoredKey(for url: URL) -> Bool {
        guard let header = try? Vault.inspect(at: url) else { return false }
        return VaultKeyStore.hasKey(salt: header.kdf.salt, for: url)
    }

    /// Remembers a document chosen in the open panel and moves to the unlock
    /// screen. The password is asked for there, not here.
    func chooseDocument(at url: URL) {
        do {
            _ = try Vault.inspect(at: url)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        documentURL = url
        UserDefaults.standard.set(url.path, forKey: Self.lastDocumentKey)
        rememberRecent(url)
        unlockErrorMessage = nil
        phase = .locked(url)
    }

    /// Moves to a document from the recent list. An open document locks first.
    func openRecent(at url: URL) {
        if isUnlocked { lock() }
        chooseDocument(at: url)
    }

    func lock() {
        vault = nil
        index = DocumentIndex(.empty)
        selection = nil
        unlockErrorMessage = nil
        if let documentURL {
            phase = .locked(documentURL)
        } else {
            phase = .welcome
        }
    }

    func forgetDocument() {
        vault = nil
        documentURL = nil
        index = DocumentIndex(.empty)
        selection = nil
        unlockErrorMessage = nil
        UserDefaults.standard.removeObject(forKey: Self.lastDocumentKey)
        phase = .welcome
    }

    private func adopt(_ vault: Vault) {
        self.vault = vault
        documentURL = vault.url
        index = DocumentIndex(vault.document)
        unlockErrorMessage = nil
        phase = .unlocked
        UserDefaults.standard.set(vault.url.path, forKey: Self.lastDocumentKey)
        rememberRecent(vault.url)
    }

    // MARK: - Security settings

    /// True when the open document has a key waiting behind Touch ID.
    var isTouchIDEnabled: Bool {
        guard let documentURL else { return false }
        return hasStoredKey(for: documentURL)
    }

    /// Remembers the open document behind Touch ID, without asking for the
    /// password again. Returns the reason it could not, or `nil` on success.
    func enableTouchID() -> String? {
        guard let vault else { return "Open the document first." }
        let material = vault.keyMaterial
        return VaultKeyStore.store(key: material.key, salt: material.salt, for: vault.url)
    }

    /// Drops the stored key. The document then opens with the password only.
    func forgetTouchIDKey() {
        guard let documentURL,
              let header = try? Vault.inspect(at: documentURL) else { return }
        VaultKeyStore.removeKey(salt: header.kdf.salt, for: documentURL)
    }

    /// Replaces the master password of the open document.
    ///
    /// The current password is proved against the file first, so a person at
    /// an unlocked Mac cannot lock the owner out. Returns the problem, or
    /// `nil` on success.
    func changeMasterPassword(current: String, to newPassword: String) async -> String? {
        guard let vault else { return "Open the document first." }
        do {
            _ = try await Vault.open(at: vault.url, password: current)
        } catch {
            return "The current password is not correct."
        }

        // The salt changes with the password, so the old Touch ID record
        // stops matching. Remember its state, then replace it.
        let hadTouchID = isTouchIDEnabled
        let oldSalt = vault.keyMaterial.salt
        do {
            try await vault.changePassword(to: newPassword)
        } catch {
            return "Termora could not save the document. \(error.localizedDescription)"
        }
        VaultKeyStore.removeKey(salt: oldSalt, for: vault.url)
        if hadTouchID {
            let material = vault.keyMaterial
            if let problem = VaultKeyStore.store(
                key: material.key, salt: material.salt, for: vault.url
            ) {
                return "The password changed, but Termora could not remember "
                    + "it for Touch ID. \(problem)"
            }
        }
        return nil
    }

    // MARK: - Changes

    /// Changes the document, rebuilds the index, and saves.
    func update(_ change: (inout Document) -> Void) {
        guard let vault else { return }
        vault.update(change)
        index = DocumentIndex(vault.document)
        save()
    }

    func save() {
        guard let vault else { return }
        do {
            try vault.save()
        } catch {
            errorMessage = "Termora could not save the document. \(error.localizedDescription)"
        }
    }

    // MARK: - Reading

    var isUnlocked: Bool { phase == .unlocked }

    var selectedConnection: Connection? {
        selection.flatMap { index.connection($0) }
    }

    var selectedFolder: Folder? {
        selection.flatMap { index.folder($0) }
    }

    /// The children of a row, with the filter applied.
    ///
    /// A folder stays in the list while any connection inside it matches, so
    /// filtering never hides the path to a result.
    /// One row of the sidebar: a node and how deep it sits.
    struct Row: Identifiable {
        let node: TreeNode
        let depth: Int
        var id: UUID { node.id }
    }

    /// The whole tree, flattened to the rows that are on screen.
    ///
    /// The sidebar draws a flat list rather than a nested one. A nested list
    /// leaves the row height to `DisclosureGroup`, which draws rows far apart.
    func visibleRows() -> [Row] {
        var rows: [Row] = []
        append(children: nil, depth: 0, into: &rows)
        return rows
    }

    private func append(children parentID: UUID?, depth: Int, into rows: inout [Row]) {
        // A tree deeper than the model allows cannot be drawn, and must not
        // turn into an endless walk.
        guard depth < Document.maximumDepth else { return }
        for node in visibleChildren(of: parentID) {
            rows.append(Row(node: node, depth: depth))
            guard case let .folder(folder) = node, isExpanded(folder) else { continue }
            append(children: folder.id, depth: depth + 1, into: &rows)
        }
    }

    /// What deleting the node would take with it, in words.
    ///
    /// Returns nil when there is nothing to delete.
    func deletionQuestion(for id: UUID) -> (title: String, detail: String)? {
        guard let node = index.node(id) else { return nil }
        switch node {
        case let .connection(connection):
            return ("Delete \"\(connection.name)\"?",
                    "The bookmark and its settings go. This cannot be undone.")
        case let .folder(folder):
            let held = index.contents(of: folder.id)
            guard held.folders > 0 || held.connections > 0 else {
                return ("Delete the folder \"\(folder.name)\"?",
                        "The folder is empty. This cannot be undone.")
            }
            var parts: [String] = []
            if held.connections > 0 {
                parts.append("\(held.connections) bookmark\(held.connections == 1 ? "" : "s")")
            }
            if held.folders > 0 {
                parts.append("\(held.folders) folder\(held.folders == 1 ? "" : "s")")
            }
            return ("Delete \"\(folder.name)\" and everything in it?",
                    "\(parts.joined(separator: " and ")) go with it. This cannot be undone.")
        }
    }

    /// Deletes the node a person has confirmed.
    func confirmDeletion() {
        guard let id = deletingID else { return }
        deletingID = nil
        update { $0.remove(id: id) }
        if selection == id { selection = nil }
        if editingID == id { editingID = nil }
    }

    /// The node a sidebar drag is carrying, while it is in flight.
    ///
    /// The sidebar draws no drop mark while this is empty, so a mark can never
    /// outlive the drag that made it. It changes twice per drag, at the start
    /// and at the end, so publishing it costs nothing.
    @Published var draggingID: UUID?

    /// Moves a node next to, or into, another node.
    @discardableResult
    func move(_ id: UUID, relativeTo target: UUID, placement: DropPlacement) -> Bool {
        var moved = false
        update { document in
            moved = document.move(id: id, relativeTo: target, placement: placement)
        }
        return moved
    }

    /// Moves a node to the top level, at the end.
    @discardableResult
    func moveToTop(_ id: UUID) -> Bool {
        var moved = false
        update { document in
            moved = document.move(id: id, toParent: nil, index: .max)
        }
        return moved
    }

    /// A filter opens every folder, so results stay visible.
    func isExpanded(_ folder: Folder) -> Bool {
        filterText.trimmingCharacters(in: .whitespaces).isEmpty ? folder.isExpanded : true
    }

    func setExpanded(_ folder: Folder, _ open: Bool) {
        guard filterText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        update { document in
            guard let at = document.folders.firstIndex(where: { $0.id == folder.id })
            else { return }
            document.folders[at].isExpanded = open
        }
    }

    func visibleChildren(of parentID: UUID?) -> [TreeNode] {
        let children = index.children(of: parentID)
        let needle = filterText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return children }
        return children.filter { matches($0, needle: needle) }
    }

    private func matches(_ node: TreeNode, needle: String) -> Bool {
        switch node {
        case let .connection(connection):
            return connection.name.localizedCaseInsensitiveContains(needle)
                || connection.host.localizedCaseInsensitiveContains(needle)
        case let .folder(folder):
            if folder.name.localizedCaseInsensitiveContains(needle) { return true }
            return index.children(of: folder.id).contains { matches($0, needle: needle) }
        }
    }

    /// Copies a connection, with everything on it, next to the original.
    func duplicate(connectionID: UUID) {
        guard let original = index.connection(connectionID) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) copy"
        copy.position = original.position + 1
        // A tunnel needs its own identifier, or the two copies would fight
        // over the same live tunnel.
        copy.forwards = original.forwards.map { forward in
            var fresh = forward
            fresh.id = UUID()
            return fresh
        }
        update { $0.add(copy) }
        selection = copy.id
    }

    /// The folder that a new item should go into, based on what is selected.
    var insertionParent: UUID? {
        if let folder = selectedFolder { return folder.id }
        if let connection = selectedConnection { return connection.parentID }
        return nil
    }

    /// Adds a connection next to the selection and opens its editor.
    func addConnection() {
        guard isUnlocked else { return }
        let parent = insertionParent
        let connection = Connection(parentID: parent, name: "New Connection",
                                    position: nextPosition(in: parent), host: "")
        update { $0.add(connection) }
        selection = connection.id
        editingID = connection.id
    }

    /// Adds a folder next to the selection and opens its editor.
    func addFolder() {
        guard isUnlocked else { return }
        let parent = insertionParent
        let folder = Folder(parentID: parent, name: "New Folder",
                            position: nextPosition(in: parent))
        update { $0.add(folder) }
        selection = folder.id
        editingID = folder.id
    }

    private func nextPosition(in parent: UUID?) -> Int {
        (index.children(of: parent).map(\.position).max() ?? -1) + 1
    }
}
