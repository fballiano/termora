import Foundation
import Testing
@testable import TermoraSFTP

/// Copying whole folders, against the real SFTP server.
@Suite(.serialized, .enabled(if: SFTPServer.isAvailable))
final class SFTPRecursiveTests {
    private let root: URL
    private let client: SFTPClient

    init() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termora-tree-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        client = SFTPClient(transport: SFTPProcessTransport(
            executable: SFTPServer.path, arguments: []
        ))
        try await client.start()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// project/
    ///   readme.txt          11 bytes
    ///   src/
    ///     main.swift        20 bytes
    ///     deep/
    ///       notes.md        5 bytes
    ///   empty/
    @discardableResult
    private func makeTree(at base: URL) throws -> URL {
        let manager = FileManager.default
        let project = base.appendingPathComponent("project")
        try manager.createDirectory(at: project.appendingPathComponent("src/deep"),
                                    withIntermediateDirectories: true)
        try manager.createDirectory(at: project.appendingPathComponent("empty"),
                                    withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: project.appendingPathComponent("readme.txt"))
        try Data(repeating: 0x41, count: 20)
            .write(to: project.appendingPathComponent("src/main.swift"))
        try Data("notes".utf8).write(to: project.appendingPathComponent("src/deep/notes.md"))
        return project
    }

    private func entry(for path: String) async throws -> SFTPEntry {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let listing = try await client.listDirectory(parent)
        return try #require(listing.first { $0.name == name })
    }

    @Test("A folder is counted before it is copied")
    func countsBeforeCopying() async throws {
        let project = try makeTree(at: root)

        let local = SFTPClient.measureLocal(project)
        #expect(local.files == 3)
        #expect(local.folders == 4, "project, src, deep, and empty.")
        #expect(local.bytes == 11 + 20 + 5)

        let remote = try await client.measureRemote(try await entry(for: project.path))
        #expect(remote == local, "Both sides must count the same tree the same way.")
    }

    @Test("A whole folder comes down, with its shape and its bytes")
    func downloadsAWholeFolder() async throws {
        let project = try makeTree(at: root)
        let destination = root.appendingPathComponent("down")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let tally = try await client.download(try await entry(for: project.path),
                                              into: destination)
        #expect(tally.files == 3)

        let copied = destination.appendingPathComponent("project")
        #expect(try Data(contentsOf: copied.appendingPathComponent("readme.txt"))
            == Data("hello world".utf8))
        #expect(try Data(contentsOf: copied.appendingPathComponent("src/deep/notes.md"))
            == Data("notes".utf8))

        // An empty folder must still arrive.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: copied.appendingPathComponent("empty").path, isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }

    @Test("A whole folder goes up, with its shape and its bytes")
    func uploadsAWholeFolder() async throws {
        let project = try makeTree(at: root)
        let remoteBase = root.appendingPathComponent("up")
        try FileManager.default.createDirectory(at: remoteBase, withIntermediateDirectories: true)

        let tally = try await client.upload(project, into: remoteBase.path)
        #expect(tally.files == 3)
        #expect(tally.folders == 4)

        let listing = try await client.listDirectory(
            remoteBase.appendingPathComponent("project/src").path
        )
        #expect(listing.map(\.name) == ["deep", "main.swift"])

        let landed = remoteBase.appendingPathComponent("project/src/deep/notes.md")
        #expect(try Data(contentsOf: landed) == Data("notes".utf8))
    }

    @Test("Progress runs to the end and never goes backwards")
    func reportsProgressAcrossAWholeFolder() async throws {
        let project = try makeTree(at: root)
        let destination = root.appendingPathComponent("progress")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let recorder = UpdateRecorder()
        try await client.download(try await entry(for: project.path), into: destination) { update in
            recorder.record(update)
        }

        #expect(recorder.count > 0, "A copy must report progress.")
        #expect(recorder.neverWentBackwards, "Progress must not go backwards between files.")
        #expect(recorder.lastBytes == 36, "Progress must reach the whole size.")
        #expect(recorder.lastFilesDone == 3)
    }

    @Test("A link is not followed, so a loop cannot make the copy run for ever")
    func doesNotFollowLinks() async throws {
        let project = try makeTree(at: root)
        // A link that points at its own parent would never end.
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("loop"),
            withDestinationURL: project
        )

        let tally = SFTPClient.measureLocal(project)
        #expect(tally.skippedLinks == 1)
        #expect(tally.files == 3, "The link must not be counted as a file.")

        let destination = root.appendingPathComponent("safe")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try await client.upload(project, into: destination.path)

        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("project/loop").path
        ), "A link is left out rather than followed.")
    }

    @Test("Copying into a folder that already holds part of the tree is allowed")
    func mergesIntoAnExistingFolder() async throws {
        let project = try makeTree(at: root)
        let remoteBase = root.appendingPathComponent("merge")
        try FileManager.default.createDirectory(
            at: remoteBase.appendingPathComponent("project/src"), withIntermediateDirectories: true
        )

        // The folders exist already. That is not a failure.
        let tally = try await client.upload(project, into: remoteBase.path)
        #expect(tally.files == 3)
        #expect(try Data(contentsOf: remoteBase.appendingPathComponent("project/src/main.swift"))
            .count == 20)
    }
}

/// Collects progress from another thread.
final class UpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [TransferUpdate] = []

    func record(_ update: TransferUpdate) {
        lock.withLock { updates.append(update) }
    }

    var count: Int { lock.withLock { updates.count } }
    var lastBytes: UInt64 { lock.withLock { updates.last?.bytesDone ?? 0 } }
    var lastFilesDone: Int { lock.withLock { updates.last?.filesDone ?? 0 } }

    var neverWentBackwards: Bool {
        lock.withLock {
            zip(updates, updates.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone }
        }
    }
}

extension SFTPRecursiveTests {
    @Test("An entry can be copied to an exact place, which is what a drag needs")
    func downloadsToAnExactPlace() async throws {
        let project = try makeTree(at: root)

        // A file, under a name the system chose.
        let file = try await entry(for: project.appendingPathComponent("readme.txt").path)
        let filePlace = root.appendingPathComponent("dropped-name.txt")
        try await client.download(file, as: filePlace)
        #expect(try Data(contentsOf: filePlace) == Data("hello world".utf8))

        // A folder, with everything inside it, at the place the system chose.
        let folder = try await entry(for: project.path)
        let folderPlace = root.appendingPathComponent("dropped-folder")
        let tally = try await client.download(folder, as: folderPlace)

        #expect(tally.files == 3)
        #expect(try Data(contentsOf: folderPlace.appendingPathComponent("src/deep/notes.md"))
            == Data("notes".utf8))
        // The name is the one asked for, not the one on the far host.
        #expect(!FileManager.default.fileExists(
            atPath: folderPlace.appendingPathComponent("project").path
        ), "The folder must land at the place given, not inside it.")
    }
}
