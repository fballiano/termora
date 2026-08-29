import CryptoKit
import Foundation
import Testing
@testable import TermoraSFTP

/// A copy must arrive byte for byte.
///
/// A file large enough to cross many pipe reads is the only way to see the
/// order the incoming chunks are put back together in. A small file fits in
/// one read and always looks correct.
@Suite(.serialized, .enabled(if: SFTPServer.isAvailable))
final class SFTPIntegrityTests {
    private let directory: URL
    private let client: SFTPClient

    init() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termora-integrity-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        client = SFTPClient(transport: SFTPProcessTransport(
            executable: SFTPServer.path, arguments: []
        ))
        try await client.start()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Bytes that never repeat, so a piece put back in the wrong place shows.
    private func pattern(_ count: Int) -> Data {
        var data = Data(capacity: count)
        var value: UInt64 = 0x1234_5678_9abc_def0
        while data.count < count {
            value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        return data.prefix(count)
    }

    @Test("A large file comes back byte for byte")
    func downloadKeepsEveryByte() async throws {
        let source = directory.appendingPathComponent("source.bin")
        let contents = pattern(4 * 1024 * 1024)
        try contents.write(to: source)

        for attempt in 1 ... 3 {
            let destination = directory.appendingPathComponent("copy-\(attempt).bin")
            try await client.download(source.path, to: destination)
            let copied = try Data(contentsOf: destination)
            #expect(copied.count == contents.count, "attempt \(attempt): wrong length")
            #expect(SHA256.hash(data: copied) == SHA256.hash(data: contents),
                    "attempt \(attempt): the bytes changed on the way")
        }
    }
}
