import Foundation
import Testing
@testable import TermoraSFTP

/// Talks to a real SFTP server.
///
/// macOS ships `/usr/libexec/sftp-server`, the same program OpenSSH runs for
/// the `sftp` subsystem. Running it directly gives the real protocol with no
/// network, no keys, and no second process to authenticate against. It serves
/// the local file system as you, so every test works inside its own temporary
/// folder and removes it afterwards.
@Suite(.serialized, .enabled(if: SFTPServer.isAvailable))
final class SFTPServerTests {
    private let directory: URL
    private let client: SFTPClient

    init() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termora-sftp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        client = SFTPClient(transport: SFTPProcessTransport(
            executable: SFTPServer.path, arguments: []
        ))
        try await client.start()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    private func writeLocal(_ name: String, _ contents: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    @Test("The server agrees version 3 and answers a real path")
    func startsAndResolvesPaths() async throws {
        let resolved = try await client.realPath(directory.path)
        #expect(resolved.hasSuffix(directory.lastPathComponent))
    }

    @Test("A folder is listed, with sizes, kinds, and no dot entries")
    func listsAFolder() async throws {
        _ = try writeLocal("alpha.txt", Data("hello".utf8))
        _ = try writeLocal("beta.log", Data(repeating: 0x41, count: 2048))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("logs"), withIntermediateDirectories: true
        )

        let entries = try await client.listDirectory(directory.path)

        #expect(entries.map(\.name) == ["logs", "alpha.txt", "beta.log"],
                "Folders come first, then names in order.")
        #expect(!entries.contains { $0.isCurrentOrParent })

        let alpha = try #require(entries.first { $0.name == "alpha.txt" })
        #expect(alpha.size == 5)
        #expect(!alpha.isDirectory)
        #expect(alpha.path == path("alpha.txt"), "An entry carries its full path.")
        #expect(alpha.attributes.permissionsText.hasPrefix("rw"))

        let logs = try #require(entries.first { $0.name == "logs" })
        #expect(logs.isDirectory)
    }

    @Test("A listing longer than one packet is read to the end")
    func listsALargeFolder() async throws {
        // The server answers READDIR in batches, so this needs several rounds.
        for index in 0 ..< 300 {
            _ = try writeLocal(String(format: "file-%03d.txt", index), Data("x".utf8))
        }
        let entries = try await client.listDirectory(directory.path)
        #expect(entries.count == 300, "Every batch of a long listing must be read.")
    }

    @Test("A file comes down with its bytes unchanged")
    func downloadsAFile() async throws {
        // Larger than one block, so more than one read is needed.
        var payload = Data()
        for index in 0 ..< 100_000 { payload.append(UInt8(index % 251)) }
        _ = try writeLocal("payload.bin", payload)

        let destination = directory.appendingPathComponent("copy.bin")
        let seen = Counter()
        try await client.download(path("payload.bin"), to: destination) { done, _ in
            seen.set(done)
        }

        #expect(try Data(contentsOf: destination) == payload)
        #expect(seen.value == UInt64(payload.count), "Progress must reach the whole size.")
    }

    @Test("A file goes up with its bytes unchanged")
    func uploadsAFile() async throws {
        var payload = Data()
        for index in 0 ..< 70_000 { payload.append(UInt8((index * 7) % 251)) }
        let source = try writeLocal("source.bin", payload)

        try await client.upload(source, to: path("uploaded.bin"))

        let landed = try Data(contentsOf: directory.appendingPathComponent("uploaded.bin"))
        #expect(landed == payload)
    }

    @Test("An empty file survives the trip in both directions")
    func handlesEmptyFiles() async throws {
        let source = try writeLocal("empty.txt", Data())
        try await client.upload(source, to: path("empty-up.txt"))
        #expect(try Data(contentsOf: directory.appendingPathComponent("empty-up.txt")).isEmpty)

        let destination = directory.appendingPathComponent("empty-down.txt")
        try await client.download(path("empty.txt"), to: destination)
        #expect(try Data(contentsOf: destination).isEmpty)
    }

    @Test("Folders and files can be made, renamed, and removed")
    func managesFilesAndFolders() async throws {
        try await client.makeDirectory(path("new-folder"))
        var attributes = try await client.stat(path("new-folder"))
        #expect(attributes.isDirectory)

        _ = try writeLocal("old-name.txt", Data("x".utf8))
        try await client.rename(path("old-name.txt"), to: path("new-name.txt"))
        attributes = try await client.stat(path("new-name.txt"))
        #expect(attributes.isRegularFile)

        try await client.removeFile(path("new-name.txt"))
        try await client.removeDirectory(path("new-folder"))

        let entries = try await client.listDirectory(directory.path)
        #expect(entries.isEmpty)
    }

    @Test("A missing file is reported clearly, and the channel keeps working")
    func reportsMissingFiles() async throws {
        await #expect(throws: SFTPError.self) {
            _ = try await client.stat(path("not-here.txt"))
        }

        do {
            _ = try await client.stat(path("not-here.txt"))
        } catch let error as SFTPError {
            guard case let .remote(code, _, _) = error else {
                Issue.record("A missing file must produce a status from the far host.")
                return
            }
            #expect(code == .noSuchFile)
            #expect(error.errorDescription?.contains("no such file") == true)
        }

        // The channel must still work after a refusal.
        _ = try writeLocal("still-here.txt", Data("ok".utf8))
        let entries = try await client.listDirectory(directory.path)
        #expect(entries.contains { $0.name == "still-here.txt" })
    }

    @Test("Removing a folder that still holds a file is refused, not obeyed")
    func refusesToRemoveAFullFolder() async throws {
        try await client.makeDirectory(path("full"))
        _ = try writeLocal("full/inside.txt", Data("x".utf8))

        await #expect(throws: SFTPError.self) {
            try await client.removeDirectory(path("full"))
        }
        #expect(FileManager.default.fileExists(atPath: path("full/inside.txt")))
    }

    @Test("Several requests can be in flight at once")
    func handlesConcurrentRequests() async throws {
        for index in 0 ..< 20 {
            _ = try writeLocal("c\(index).txt", Data(String(repeating: "x", count: index).utf8))
        }

        // Each reply must find its own request, whatever order they arrive in.
        // The paths are made first, so the tasks capture only Sendable values.
        let paths = (0 ..< 20).map { path("c\($0).txt") }
        let client = client
        let sizes = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for remotePath in paths {
                group.addTask {
                    try await client.stat(remotePath).size ?? 0
                }
            }
            var collected: [UInt64] = []
            for try await size in group { collected.append(size) }
            return collected.sorted()
        }
        #expect(sizes == (0 ..< 20).map(UInt64.init))
    }
}

/// The progress callback runs on another thread, so the test reads it behind
/// a lock rather than capturing a plain variable.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64 = 0

    var value: UInt64 { lock.withLock { stored } }
    func set(_ newValue: UInt64) { lock.withLock { stored = newValue } }
}

enum SFTPServer {
    static let path = "/usr/libexec/sftp-server"
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
