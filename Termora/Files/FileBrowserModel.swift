//
//  FileBrowserModel.swift
//  Termora
//

import AppKit
import Foundation
import TermoraSFTP
import TermoraSSH
import UniformTypeIdentifiers

/// Browses the files of one connection.
///
/// The channel travels on the SSH connection that is already open, so nothing
/// authenticates a second time and closing the browser does not disturb any
/// terminal pane.
@MainActor
final class FileBrowserModel: ObservableObject {
    enum State: Equatable {
        case opening
        case ready
        case failed(String)
    }

    struct Transfer: Equatable {
        var update: TransferUpdate
        var isUpload: Bool

        var name: String { update.currentName }
        var fraction: Double { update.fraction }
        var done: UInt64 { update.bytesDone }
        var total: UInt64 { update.total.bytes }
        /// `3 of 12 files`, shown only when there is more than one.
        var fileCount: String? {
            update.total.files > 1 ? "\(update.filesDone) of \(update.total.files) files" : nil
        }
    }

    @Published private(set) var state: State = .opening
    @Published private(set) var currentPath = ""
    @Published private(set) var entries: [SFTPEntry] = []
    @Published var selection: Set<String> = []
    @Published private(set) var transfer: Transfer?
    @Published var errorMessage: String?
    @Published var isBusy = false
    /// Set by the table when a right-click asks to rename or delete. The view
    /// puts the question on screen, because AppKit has no sheet of its own here.
    @Published var renameRequest: SFTPEntry?
    @Published var deleteRequest: [SFTPEntry] = []

    /// Set by the owner. Opens one remote file in an editor on this Mac; the
    /// second value is the application to use, or `nil` for the chosen one.
    var onEdit: ((SFTPEntry, URL?) -> Void)?

    private var client: SFTPClient?
    private var transport: SFTPProcessTransport?
    private let sshConnection: SSHConnection

    init(sshConnection: SSHConnection) {
        self.sshConnection = sshConnection
    }

    var connectionID: UUID { sshConnection.id }

    var canGoUp: Bool {
        currentPath != "/" && !currentPath.isEmpty
    }

    var selectedEntries: [SFTPEntry] {
        entries.filter { selection.contains($0.path) }
    }

    // MARK: - Opening

    func open() async {
        state = .opening
        let transport = SFTPProcessTransport(
            executable: SSHCommand.executable,
            arguments: sshConnection.sftpArguments()
        )
        self.transport = transport
        let client = SFTPClient(transport: transport)
        self.client = client

        do {
            try await client.start()
            let home = try await client.realPath(".")
            state = .ready
            await go(to: home)
        } catch {
            // ssh says on standard error why the channel did not open, and
            // the last line is the one that names the problem.
            var reason = error.localizedDescription
            let said = transport.errorOutput
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            if let said, !reason.contains(said) {
                reason += "\n" + said
            }
            state = .failed(reason)
        }
    }

    func close() {
        let client = client
        self.client = nil
        Task { await client?.stop() }
    }

    // MARK: - Moving about

    func go(to path: String) async {
        guard let client, state == .ready else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let listing = try await client.listDirectory(path)
            currentPath = path
            entries = listing
            selection = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func goUp() async {
        guard canGoUp else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        await go(to: parent.isEmpty ? "/" : parent)
    }

    func refresh() async {
        await go(to: currentPath)
    }

    func open(_ entry: SFTPEntry) async {
        if entry.isDirectory {
            await go(to: entry.path)
        } else if let onEdit {
            // A double-click opens the file the way Finder would: a copy
            // comes to this Mac, opens in an editor, and each save goes back.
            onEdit(entry, nil)
        } else {
            await download([entry])
        }
    }

    // MARK: - Changing things

    func makeFolder(named name: String) async {
        guard let client, !name.isEmpty else { return }
        do {
            try await client.makeDirectory(SFTPClient.join(currentPath, name))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ entry: SFTPEntry, to name: String) async {
        guard let client, !name.isEmpty, name != entry.name else { return }
        do {
            try await client.rename(entry.path, to: SFTPClient.join(currentPath, name))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes the chosen entries. The caller asks first.
    func delete(_ chosen: [SFTPEntry]) async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }

        for entry in chosen {
            do {
                if entry.isDirectory {
                    try await client.removeDirectory(entry.path)
                } else {
                    try await client.removeFile(entry.path)
                }
            } catch {
                // Say which one failed, and stop rather than carry on blindly.
                errorMessage = "Termora could not remove \(entry.name). "
                    + error.localizedDescription
                break
            }
        }
        await refresh()
    }

    // MARK: - Transfers

    func download(_ chosen: [SFTPEntry]) async {
        guard let client, !chosen.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Where should Termora put the files?"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isBusy = true
        defer { isBusy = false; transfer = nil }

        for entry in chosen {
            do {
                let tally = try await client.download(entry, into: destination) { [weak self] update in
                    Task { @MainActor in
                        self?.transfer = Transfer(update: update, isUpload: false)
                    }
                }
                if tally.skippedLinks > 0 {
                    errorMessage = "Termora left out \(tally.skippedLinks) link(s) in "
                        + "\(entry.name). Links are not followed."
                }
            } catch {
                errorMessage = "Termora could not copy \(entry.name). \(error.localizedDescription)"
                break
            }
        }
    }

    /// Copies an entry to the exact place the system asked for.
    ///
    /// A drag to Finder uses this. Finder names the destination, and expects
    /// the item to be there when the copy ends.
    func copy(_ entry: SFTPEntry, to destination: URL) async throws {
        guard let client else { throw SFTPError.channelClosed }
        isBusy = true
        defer { isBusy = false; transfer = nil }

        _ = try await client.download(entry, as: destination) { [weak self] update in
            Task { @MainActor in
                self?.transfer = Transfer(update: update, isUpload: false)
            }
        }
    }

    func upload(_ urls: [URL]) async {
        guard let client, !urls.isEmpty else { return }
        isBusy = true
        defer { isBusy = false; transfer = nil }

        var skippedLinks = 0
        for url in urls {
            do {
                let tally = try await client.upload(url, into: currentPath) { [weak self] update in
                    Task { @MainActor in
                        self?.transfer = Transfer(update: update, isUpload: true)
                    }
                }
                skippedLinks += tally.skippedLinks
            } catch {
                errorMessage = "Termora could not copy \(url.lastPathComponent). "
                    + error.localizedDescription
                break
            }
        }
        if skippedLinks > 0 {
            errorMessage = "Termora left out \(skippedLinks) link(s). Links are not followed."
        }
        await refresh()
    }

    func chooseFilesToUpload() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        // A folder is copied with everything inside it.
        panel.canChooseDirectories = true
        panel.message = "Choose the files or folders to copy to the far host."
        guard panel.runModal() == .OK else { return }
        await upload(panel.urls)
    }

}
