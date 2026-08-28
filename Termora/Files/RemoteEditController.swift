//
//  RemoteEditController.swift
//  Termora
//

import AppKit
import Foundation
import TermoraSFTP
import TermoraSSH

/// One remote file open in an editor on this Mac.
///
/// The file lives in a private folder while the edit lasts. Each save in the
/// editor is copied back to the same remote path, which keeps the remote
/// owner and permissions.
@MainActor
final class RemoteEdit: ObservableObject, Identifiable {
    enum Activity: Equatable {
        case downloading
        case idle
        case uploading
        case failed(String)
    }

    let id = UUID()
    let connection: SSHConnection
    let remotePath: String
    let name: String
    /// The private folder holding the copy, one per edit.
    let folderURL: URL
    let localURL: URL

    @Published var activity: Activity = .downloading

    /// The change date of the local copy at the last successful sync. A save
    /// moves it, and that is the signal to upload.
    var localModifiedAt: Date?
    /// The change date of the remote file at the last successful sync. A
    /// difference before an upload means someone else changed the file.
    var remoteModifiedAt: Date?
    var watcher: (any DispatchSourceFileSystemObject)?
    var pendingCheck: Task<Void, Never>?

    init(entry: SFTPEntry, connection: SSHConnection, folderURL: URL) {
        self.connection = connection
        self.remotePath = entry.path
        self.name = entry.name
        self.folderURL = folderURL
        self.localURL = folderURL.appendingPathComponent(entry.name)
    }
}

/// Edits remote files in place: copy down, open, watch, copy back.
///
/// The controller lives as long as the application, not as long as a file
/// browser view, because an editor stays open after the browser tab closes.
/// Each transfer opens its own SFTP channel on the connection's control
/// master, so nothing authenticates a second time and no idle channel is
/// kept.
@MainActor
final class RemoteEditController: ObservableObject {
    @Published private(set) var edits: [RemoteEdit] = []
    @Published var errorMessage: String?
    /// An edit whose remote file changed after the copy was taken. The view
    /// asks before the upload overwrites those changes.
    @Published var conflicted: RemoteEdit?

    /// How long to wait after a folder event before looking, so an editor
    /// that saves in several steps is read once, at the end.
    private static let settleAfterSave = Duration.milliseconds(400)

    private static var editsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Termora/Edits", isDirectory: true)
    }

    init() {
        // A copy left behind by a crash serves no one. Remove them all;
        // every live edit makes its own fresh folder.
        try? FileManager.default.removeItem(at: Self.editsRoot)
    }

    // MARK: - Starting an edit

    /// Copies the file down, opens it, and watches for saves.
    ///
    /// `application` is the editor to use for this one file. `nil` uses the
    /// editor from Settings, or the default application for the file's type.
    func edit(_ entry: SFTPEntry, on connection: SSHConnection, with application: URL?) {
        guard !entry.isDirectory, !entry.isSymbolicLink else { return }

        // The same file again only brings the editor forward.
        if let existing = edits.first(where: {
            $0.connection.id == connection.id && $0.remotePath == entry.path
        }) {
            openInEditor(existing, with: application)
            return
        }

        let folder = Self.editsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let edit = RemoteEdit(entry: entry, connection: connection, folderURL: folder)
        edits.append(edit)
        Task { await start(edit, with: application) }
    }

    private func start(_ edit: RemoteEdit, with application: URL?) async {
        do {
            // Only this user may read the folder: the copy is plain on disk.
            try FileManager.default.createDirectory(
                at: edit.folderURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try await withChannel(on: edit.connection) { client in
                edit.remoteModifiedAt = try await client.stat(edit.remotePath).modifiedAt
                try await client.download(edit.remotePath, to: edit.localURL)
            }
            edit.localModifiedAt = localChangeDate(of: edit)
            edit.activity = .idle
            startWatching(edit)
            openInEditor(edit, with: application)
        } catch {
            end(edit)
            errorMessage = "Termora could not open \(edit.name) for editing. "
                + error.localizedDescription
        }
    }

    private func openInEditor(_ edit: RemoteEdit, with application: URL?) {
        let chosen = application ?? AppSettings.remoteEditorURL
        guard let chosen else {
            if !NSWorkspace.shared.open(edit.localURL) {
                errorMessage = "No application on this Mac opens \(edit.name)."
            }
            return
        }
        NSWorkspace.shared.open(
            [edit.localURL], withApplicationAt: chosen,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            guard let error else { return }
            Task { @MainActor in
                self.errorMessage = "Termora could not open \(edit.name) in "
                    + "\(chosen.deletingPathExtension().lastPathComponent). "
                    + error.localizedDescription
            }
        }
    }

    // MARK: - Watching for saves

    /// Watches the edit's folder, not the file. Most editors save by writing
    /// a new file and renaming it into place, which replaces the file the
    /// watch would hold.
    private func startWatching(_ edit: RemoteEdit) {
        let descriptor = open(edit.folderURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak edit] in
            // The queue is the main queue, so this runs on the main actor.
            MainActor.assumeIsolated {
                guard let self, let edit else { return }
                self.scheduleCheck(edit)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        edit.watcher = source
    }

    private func scheduleCheck(_ edit: RemoteEdit) {
        edit.pendingCheck?.cancel()
        edit.pendingCheck = Task { [weak self, weak edit] in
            try? await Task.sleep(for: Self.settleAfterSave)
            guard !Task.isCancelled, let self, let edit else { return }
            await self.uploadIfChanged(edit)
        }
    }

    private func uploadIfChanged(_ edit: RemoteEdit) async {
        guard edit.activity != .downloading else { return }
        if edit.activity == .uploading {
            // A save landed while the last one is still going up. Look again
            // once the running upload has ended.
            scheduleCheck(edit)
            return
        }
        guard let changed = localChangeDate(of: edit), changed != edit.localModifiedAt
        else { return }
        await upload(edit, force: false)
    }

    // MARK: - Uploading

    /// A marker thrown when the remote file changed under the edit.
    private struct RemoteFileChanged: Error {}

    /// Copies the local file back to its remote path. With `force` false, a
    /// remote file that changed since the last sync is not touched: the view
    /// asks first, then calls again with `force` true.
    func upload(_ edit: RemoteEdit, force: Bool) async {
        guard edit.connection.isConnected else {
            edit.activity = .failed("The connection is closed.")
            errorMessage = "Termora could not copy \(edit.name) back. "
                + "The connection to \(edit.connection.name) is closed."
            return
        }

        let changed = localChangeDate(of: edit)
        edit.activity = .uploading
        do {
            try await withChannel(on: edit.connection) { client in
                if !force, let recorded = edit.remoteModifiedAt,
                   let remote = try await client.stat(edit.remotePath).modifiedAt,
                   remote != recorded {
                    throw RemoteFileChanged()
                }
                try await client.upload(edit.localURL, to: edit.remotePath)
                edit.remoteModifiedAt = try await client.stat(edit.remotePath).modifiedAt
            }
            edit.localModifiedAt = changed
            edit.activity = .idle
        } catch is RemoteFileChanged {
            edit.activity = .idle
            conflicted = edit
        } catch {
            edit.activity = .failed(error.localizedDescription)
            errorMessage = "Termora could not copy \(edit.name) back to "
                + "\(edit.connection.name). \(error.localizedDescription)"
        }
    }

    // MARK: - Ending

    /// Stops the watch and removes the local copy.
    func end(_ edit: RemoteEdit) {
        edit.pendingCheck?.cancel()
        edit.pendingCheck = nil
        edit.watcher?.cancel()
        edit.watcher = nil
        try? FileManager.default.removeItem(at: edit.folderURL)
        edits.removeAll { $0.id == edit.id }
        if conflicted?.id == edit.id { conflicted = nil }
    }

    /// Called when a connection closes. Its edits cannot upload any more.
    func connectionClosed(_ connectionID: UUID) {
        for edit in edits where edit.connection.id == connectionID {
            end(edit)
        }
    }

    func endAll() {
        for edit in edits { end(edit) }
    }

    // MARK: - The channel

    /// Opens an SFTP channel on the control master, does the work, and closes
    /// the channel again.
    private func withChannel<T: Sendable>(
        on connection: SSHConnection,
        _ work: @MainActor (SFTPClient) async throws -> T
    ) async throws -> T {
        let client = SFTPClient(transport: SFTPProcessTransport(
            executable: SSHCommand.executable,
            arguments: connection.sftpArguments()
        ))
        try await client.start()
        do {
            let result = try await work(client)
            await client.stop()
            return result
        } catch {
            await client.stop()
            throw error
        }
    }

    private func localChangeDate(of edit: RemoteEdit) -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: edit.localURL.path)[.modificationDate] as? Date
    }
}
