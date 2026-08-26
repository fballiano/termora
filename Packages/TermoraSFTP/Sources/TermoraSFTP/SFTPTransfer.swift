//
//  SFTPTransfer.swift
//  TermoraSFTP
//

import Foundation

/// How much work a copy will be, counted before it starts.
///
/// The browser needs this to show one honest progress bar for a whole folder
/// rather than a bar that restarts at every file.
public struct TransferTally: Hashable, Sendable {
    public var files = 0
    public var folders = 0
    public var bytes: UInt64 = 0
    /// Links are not followed, so a loop cannot make the copy run for ever.
    public var skippedLinks = 0

    public var isEmpty: Bool { files == 0 && folders == 0 }

    public static func + (left: TransferTally, right: TransferTally) -> TransferTally {
        TransferTally(
            files: left.files + right.files,
            folders: left.folders + right.folders,
            bytes: left.bytes + right.bytes,
            skippedLinks: left.skippedLinks + right.skippedLinks
        )
    }
}

/// Where a copy has got to.
public struct TransferUpdate: Hashable, Sendable {
    public var currentName: String
    public var filesDone: Int
    public var bytesDone: UInt64
    public var total: TransferTally

    public var fraction: Double {
        guard total.bytes > 0 else {
            guard total.files > 0 else { return 0 }
            return min(1, Double(filesDone) / Double(total.files))
        }
        return min(1, Double(bytesDone) / Double(total.bytes))
    }
}

public typealias TransferProgress = @Sendable (TransferUpdate) -> Void

public extension SFTPClient {
    /// How deep a copy may go. A tree deeper than this is almost certainly a
    /// mistake, and the limit keeps a damaged listing from running away.
    static var maximumDepth: Int { 64 }

    // MARK: - Counting first

    /// Counts what copying this entry from the far host would involve.
    func measureRemote(_ entry: SFTPEntry) async throws -> TransferTally {
        guard entry.isDirectory else {
            if entry.isSymbolicLink { return TransferTally(skippedLinks: 1) }
            return TransferTally(files: 1, bytes: entry.size)
        }
        return try await measureRemoteFolder(entry.path, depth: 0)
    }

    private func measureRemoteFolder(_ path: String, depth: Int) async throws -> TransferTally {
        guard depth < Self.maximumDepth else { return TransferTally() }
        var tally = TransferTally(folders: 1)
        for child in try await listDirectory(path) {
            if child.isSymbolicLink {
                tally.skippedLinks += 1
            } else if child.isDirectory {
                tally = tally + (try await measureRemoteFolder(child.path, depth: depth + 1))
            } else {
                tally.files += 1
                tally.bytes += child.size
            }
        }
        return tally
    }

    /// Counts what copying this file or folder to the far host would involve.
    nonisolated static func measureLocal(_ url: URL) -> TransferTally {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return TransferTally()
        }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return TransferTally(skippedLinks: 1) }

        guard isDirectory.boolValue else {
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            return TransferTally(files: 1, bytes: size)
        }

        var tally = TransferTally(folders: 1)
        let contents = (try? manager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        )) ?? []
        for child in contents { tally = tally + measureLocal(child) }
        return tally
    }

    // MARK: - Copying a file or a whole folder

    /// Copies one entry from the far host into a folder on this Mac.
    ///
    /// A folder is copied with everything inside it. Links are not followed.
    @discardableResult
    func download(
        _ entry: SFTPEntry,
        into localDirectory: URL,
        progress: TransferProgress? = nil
    ) async throws -> TransferTally {
        let tally = try await measureRemote(entry)
        var state = TransferUpdate(currentName: entry.name, filesDone: 0,
                                   bytesDone: 0, total: tally)
        try await downloadItem(entry, into: localDirectory, state: &state,
                               progress: progress, depth: 0)
        return tally
    }

    /// Copies one entry to an exact place, rather than into a folder.
    ///
    /// A drag to Finder needs this: the system says where the item must land,
    /// name included, and expects to find it there when the copy ends.
    @discardableResult
    func download(
        _ entry: SFTPEntry,
        as destination: URL,
        progress: TransferProgress? = nil
    ) async throws -> TransferTally {
        let tally = try await measureRemote(entry)
        var state = TransferUpdate(currentName: entry.name, filesDone: 0,
                                   bytesDone: 0, total: tally)

        if entry.isDirectory {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true
            )
            for child in try await listDirectory(entry.path) {
                try await downloadItem(child, into: destination, state: &state,
                                       progress: progress, depth: 1)
            }
        } else if !entry.isSymbolicLink {
            let name = entry.name
            let total = tally
            try await download(entry.path, to: destination) { done, _ in
                progress?(TransferUpdate(currentName: name, filesDone: 0,
                                         bytesDone: done, total: total))
            }
        }
        return tally
    }

    private func downloadItem(
        _ entry: SFTPEntry,
        into localDirectory: URL,
        state: inout TransferUpdate,
        progress: TransferProgress?,
        depth: Int
    ) async throws {
        guard depth < Self.maximumDepth else { return }
        if entry.isSymbolicLink { return }

        let destination = localDirectory.appendingPathComponent(entry.name)

        guard entry.isDirectory else {
            state.currentName = entry.name
            // Copy what the callback needs. A closure that runs on another
            // thread may not reach into an inout parameter.
            let alreadyDone = state.bytesDone
            let filesDone = state.filesDone
            let total = state.total
            let name = entry.name
            try await download(entry.path, to: destination) { done, _ in
                progress?(TransferUpdate(
                    currentName: name,
                    filesDone: filesDone,
                    bytesDone: alreadyDone + done,
                    total: total
                ))
            }
            state.filesDone += 1
            state.bytesDone = alreadyDone + entry.size
            progress?(state)
            return
        }

        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true
        )
        for child in try await listDirectory(entry.path) {
            try await downloadItem(child, into: destination, state: &state,
                                   progress: progress, depth: depth + 1)
        }
    }

    /// Copies one file or folder from this Mac into a folder on the far host.
    @discardableResult
    func upload(
        _ localURL: URL,
        into remoteDirectory: String,
        progress: TransferProgress? = nil
    ) async throws -> TransferTally {
        let tally = SFTPClient.measureLocal(localURL)
        var state = TransferUpdate(currentName: localURL.lastPathComponent,
                                   filesDone: 0, bytesDone: 0, total: tally)
        try await uploadItem(localURL, into: remoteDirectory, state: &state,
                             progress: progress, depth: 0)
        return tally
    }

    private func uploadItem(
        _ localURL: URL,
        into remoteDirectory: String,
        state: inout TransferUpdate,
        progress: TransferProgress?,
        depth: Int
    ) async throws {
        guard depth < Self.maximumDepth else { return }

        let manager = FileManager.default
        if (try? localURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else { return }

        let name = localURL.lastPathComponent
        let remotePath = SFTPClient.join(remoteDirectory, name)

        guard isDirectory.boolValue else {
            state.currentName = name
            let alreadyDone = state.bytesDone
            let filesDone = state.filesDone
            let total = state.total
            try await upload(localURL, to: remotePath) { done, _ in
                progress?(TransferUpdate(
                    currentName: name,
                    filesDone: filesDone,
                    bytesDone: alreadyDone + done,
                    total: total
                ))
            }
            let size = (try? manager.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
            state.filesDone += 1
            state.bytesDone = alreadyDone + size
            progress?(state)
            return
        }

        // A folder that is already there is not an error.
        try await makeDirectoryIfNeeded(remotePath)
        let contents = (try? manager.contentsOfDirectory(
            at: localURL, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        )) ?? []
        for child in contents {
            try await uploadItem(child, into: remotePath, state: &state,
                                 progress: progress, depth: depth + 1)
        }
    }

    /// Makes a folder, and says nothing when it is already there.
    func makeDirectoryIfNeeded(_ path: String) async throws {
        do {
            try await makeDirectory(path)
        } catch let error as SFTPError {
            guard let existing = try? await stat(path), existing.isDirectory else { throw error }
        }
    }
}
