import Foundation
import Testing
@testable import TermoraSFTP

/// A transport that never answers anything.
private final class SilentTransport: SFTPTransport, @unchecked Sendable {
    func start(onData: @escaping @Sendable (Data) -> Void,
               onClose: @escaping @Sendable () -> Void) throws {}
    func send(_ data: Data) throws {}
    func stop() {}
}

/// A transport whose replies are written by the test.
///
/// It answers the version handshake itself. Every other request goes to the
/// `respond` closure with its type and its request number; the closure
/// returns the reply packet, or `nil` to stay silent.
private final class ScriptedTransport: SFTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable (Data) -> Void)?
    private let respond: @Sendable (SFTPPacketType, UInt32) throws -> Data?

    init(respond: @escaping @Sendable (SFTPPacketType, UInt32) throws -> Data?) {
        self.respond = respond
    }

    func start(onData: @escaping @Sendable (Data) -> Void,
               onClose: @escaping @Sendable () -> Void) throws {
        lock.withLock { deliver = onData }
    }

    func send(_ data: Data) throws {
        var reader = SFTPReader(data)
        _ = try reader.readUInt32()
        guard let type = SFTPPacketType(rawValue: try reader.readUInt8()) else { return }

        let reply: Data?
        if type == .initialise {
            reply = SFTPWriter.packet(.version) { $0.write(SFTPClient.version) }
        } else {
            let id = try reader.readUInt32()
            reply = try respond(type, id)
        }
        guard let reply, let deliver = lock.withLock({ deliver }) else { return }
        deliver(reply)
    }

    func stop() {}
}

private func status(_ code: SFTPStatusCode, id: UInt32, message: String = "") -> Data {
    SFTPWriter.packet(.status) {
        $0.write(id)
        $0.write(code.rawValue)
        $0.write(message)
        $0.write("")
    }
}

@Test("A read that fails mid-file is thrown, not passed off as the end")
func failedReadDoesNotTruncate() async throws {
    // The far host says the file holds 100 bytes, hands over 50, and then
    // reports a failure. The old client broke out of its loop and reported
    // success on a half file.
    let reads = Reads()
    let transport = ScriptedTransport { type, id in
        switch type {
        case .stat:
            return SFTPWriter.packet(.attributes) {
                $0.write(id)
                $0.write(SFTPAttributes(size: 100))
            }
        case .open:
            return SFTPWriter.packet(.handle) {
                $0.write(id)
                $0.write(Data([1]))
            }
        case .read:
            if reads.first() {
                return SFTPWriter.packet(.data) {
                    $0.write(id)
                    $0.write(Data(repeating: 7, count: 50))
                }
            }
            return status(.failure, id: id, message: "the channel broke")
        default:
            return status(.ok, id: id)
        }
    }

    let destination = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("termora-truncated-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: destination) }

    let client = SFTPClient(transport: transport)
    try await client.start()

    await #expect(throws: SFTPError.self) {
        try await client.download("/far/file", to: destination)
    }
}

/// Counts the reads across the Sendable closure above.
private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func first() -> Bool {
        lock.withLock {
            count += 1
            return count == 1
        }
    }
}

@Test("A far host that never answers the handshake times out")
func handshakeTimesOut() async {
    let client = SFTPClient(transport: SilentTransport(),
                            requestTimeout: .milliseconds(50))
    await #expect(throws: SFTPError.self) {
        try await client.start()
    }
}

@Test("A far host that goes quiet after the handshake times out")
func requestTimesOut() async throws {
    // Every request after the handshake is left without an answer.
    let transport = ScriptedTransport { _, _ in nil }
    let client = SFTPClient(transport: transport,
                            requestTimeout: .milliseconds(50))
    try await client.start()

    do {
        _ = try await client.stat("/anywhere")
        Issue.record("The request must not return without a reply.")
    } catch let error as SFTPError {
        guard case .timedOut = error else {
            Issue.record("The error must say it timed out, not \(error).")
            return
        }
    }
}
