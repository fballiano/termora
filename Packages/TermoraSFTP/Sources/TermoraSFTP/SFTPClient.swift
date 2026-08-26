//
//  SFTPClient.swift
//  TermoraSFTP
//

import Foundation

/// An SFTP version 3 client.
///
/// Termora speaks the protocol itself, on a channel that the already open SSH
/// connection carries. That means no second authentication, no second
/// password, and no cryptography in Termora.
///
/// Every request gets a number, and the reply is matched back to it, so
/// several reads or writes can be in flight at once.
public actor SFTPClient {
    public static let version: UInt32 = 3
    /// OpenSSH accepts more, but 32 KiB is the size every server handles.
    public static let blockSize = 32 * 1024
    /// How many reads or writes to keep in flight during a transfer.
    public static let transferWindow = 8

    private let transport: any SFTPTransport
    private var nextRequestID: UInt32 = 1
    private var waiting: [UInt32: CheckedContinuation<SFTPReply, any Error>] = [:]
    private var incoming = Data()
    private var isClosed = false
    private var versionWaiter: CheckedContinuation<UInt32, any Error>?

    /// A reply, already split into its parts.
    enum SFTPReply {
        case status(SFTPStatusCode, message: String)
        case handle(Data)
        case data(Data)
        case names([(name: String, longName: String, attributes: SFTPAttributes)])
        case attributes(SFTPAttributes)
    }

    public init(transport: any SFTPTransport) {
        self.transport = transport
    }

    // MARK: - Opening and closing

    /// Starts the channel and agrees the version.
    public func start() async throws {
        try transport.start(
            onData: { [weak self] data in
                Task { await self?.receive(data) }
            },
            onClose: { [weak self] in
                Task { await self?.channelClosed() }
            }
        )

        try transport.send(SFTPWriter.packet(.initialise) { $0.write(Self.version) })

        let agreed = try await withCheckedThrowingContinuation { continuation in
            versionWaiter = continuation
        }
        guard agreed >= 3 else { throw SFTPError.unsupportedVersion(agreed) }
    }

    public func stop() {
        isClosed = true
        transport.stop()
        failEveryWaiter(with: SFTPError.channelClosed)
    }

    // MARK: - Folders

    /// Turns a path such as `.` or `~/logs` into a full path.
    public func realPath(_ path: String) async throws -> String {
        let reply = try await send(.realpath, path: path) { $0.write(path) }
        guard case let .names(entries) = reply, let first = entries.first else {
            throw SFTPError.malformedPacket("The far host sent no path.")
        }
        return first.name
    }

    /// Lists a folder. `.` and `..` are left out.
    public func listDirectory(_ path: String) async throws -> [SFTPEntry] {
        let handle = try await openDirectory(path)
        defer { Task { try? await closeHandle(handle) } }

        var entries: [SFTPEntry] = []
        while true {
            do {
                let reply = try await send(.readdir, path: path) { $0.write(handle) }
                guard case let .names(names) = reply else { break }
                for item in names where item.name != "." && item.name != ".." {
                    entries.append(SFTPEntry(
                        name: item.name,
                        path: Self.join(path, item.name),
                        longName: item.longName,
                        attributes: item.attributes
                    ))
                }
            } catch let error as SFTPError where error.isEndOfFile {
                break
            }
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func stat(_ path: String) async throws -> SFTPAttributes {
        let reply = try await send(.stat, path: path) { $0.write(path) }
        guard case let .attributes(attributes) = reply else {
            throw SFTPError.malformedPacket("The far host sent no attributes.")
        }
        return attributes
    }

    public func makeDirectory(_ path: String) async throws {
        _ = try await expectOK(.mkdir, path: path) {
            $0.write(path)
            $0.write(SFTPAttributes())
        }
    }

    public func removeDirectory(_ path: String) async throws {
        _ = try await expectOK(.rmdir, path: path) { $0.write(path) }
    }

    public func removeFile(_ path: String) async throws {
        _ = try await expectOK(.remove, path: path) { $0.write(path) }
    }

    public func rename(_ path: String, to newPath: String) async throws {
        _ = try await expectOK(.rename, path: path) {
            $0.write(path)
            $0.write(newPath)
        }
    }

    // MARK: - Files

    /// Copies a file from the far host. `progress` reports bytes so far.
    public func download(
        _ remotePath: String,
        to localURL: URL,
        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil
    ) async throws {
        let total = try await stat(remotePath).size ?? 0
        let handle = try await openFile(remotePath, flags: .read)
        defer { Task { try? await closeHandle(handle) } }

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let file = try? FileHandle(forWritingTo: localURL) else {
            throw SFTPError.cannotReadLocalFile(localURL.path)
        }
        defer { try? file.close() }

        var offset: UInt64 = 0
        while true {
            let reply = try? await send(.read, path: remotePath) {
                $0.write(handle)
                $0.write(offset)
                $0.write(UInt32(Self.blockSize))
            }
            guard let reply, case let .data(chunk) = reply, !chunk.isEmpty else { break }

            try file.write(contentsOf: chunk)
            offset += UInt64(chunk.count)
            progress?(offset, max(total, offset))
            if chunk.count < Self.blockSize, offset >= total, total > 0 { break }
        }
    }

    /// Copies a file to the far host.
    public func upload(
        _ localURL: URL,
        to remotePath: String,
        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil
    ) async throws {
        guard let file = try? FileHandle(forReadingFrom: localURL) else {
            throw SFTPError.cannotReadLocalFile(localURL.path)
        }
        defer { try? file.close() }
        let total = (try? FileManager.default
            .attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0

        let handle = try await openFile(
            remotePath, flags: [.write, .create, .truncate]
        )
        defer { Task { try? await closeHandle(handle) } }

        var offset: UInt64 = 0
        while true {
            let chunk = try file.read(upToCount: Self.blockSize) ?? Data()
            if chunk.isEmpty { break }
            _ = try await expectOK(.write, path: remotePath) {
                $0.write(handle)
                $0.write(offset)
                $0.write(chunk)
            }
            offset += UInt64(chunk.count)
            progress?(offset, max(total, offset))
        }
    }

    // MARK: - Handles

    private func openDirectory(_ path: String) async throws -> Data {
        let reply = try await send(.opendir, path: path) { $0.write(path) }
        guard case let .handle(handle) = reply else {
            throw SFTPError.malformedPacket("The far host sent no folder handle.")
        }
        return handle
    }

    private func openFile(_ path: String, flags: SFTPOpenFlags) async throws -> Data {
        let reply = try await send(.open, path: path) {
            $0.write(path)
            $0.write(flags.rawValue)
            $0.write(SFTPAttributes())
        }
        guard case let .handle(handle) = reply else {
            throw SFTPError.malformedPacket("The far host sent no file handle.")
        }
        return handle
    }

    private func closeHandle(_ handle: Data) async throws {
        _ = try await expectOK(.close, path: "") { $0.write(handle) }
    }

    // MARK: - Sending and matching

    @discardableResult
    private func expectOK(
        _ type: SFTPPacketType,
        path: String,
        _ body: (inout SFTPWriter) -> Void
    ) async throws -> SFTPReply {
        let reply = try await send(type, path: path, body)
        if case let .status(code, message) = reply, code != .ok {
            throw SFTPError.remote(code, path: path, detail: message)
        }
        return reply
    }

    private func send(
        _ type: SFTPPacketType,
        path: String,
        _ body: (inout SFTPWriter) -> Void
    ) async throws -> SFTPReply {
        guard !isClosed else { throw SFTPError.channelClosed }

        let id = nextRequestID
        nextRequestID &+= 1
        if nextRequestID == 0 { nextRequestID = 1 }

        let packet = SFTPWriter.packet(type) { writer in
            writer.write(id)
            body(&writer)
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            do {
                try transport.send(packet)
            } catch {
                waiting[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Receiving

    /// Collects bytes and takes out whole packets.
    ///
    /// A read from a pipe stops wherever it likes, so a packet may arrive in
    /// pieces, and several packets may arrive together.
    private func receive(_ chunk: Data) {
        incoming.append(chunk)

        while incoming.count >= 4 {
            var header = SFTPReader(incoming.prefix(4))
            guard let length = try? header.readUInt32() else { return }
            let total = 4 + Int(length)
            guard length > 0, incoming.count >= total else { return }

            let body = incoming.subdata(in: 4 ..< total)
            incoming.removeSubrange(0 ..< total)
            handle(body)
        }
    }

    private func handle(_ body: Data) {
        var reader = SFTPReader(body)
        guard let rawType = try? reader.readUInt8(),
              let type = SFTPPacketType(rawValue: rawType)
        else { return }

        if type == .version {
            let agreed = (try? reader.readUInt32()) ?? 0
            versionWaiter?.resume(returning: agreed)
            versionWaiter = nil
            return
        }

        guard let id = try? reader.readUInt32(),
              let continuation = waiting.removeValue(forKey: id)
        else { return }

        do {
            continuation.resume(returning: try parse(type, &reader))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func parse(_ type: SFTPPacketType, _ reader: inout SFTPReader) throws -> SFTPReply {
        switch type {
        case .status:
            let code = SFTPStatusCode(rawValue: try reader.readUInt32()) ?? .failure
            // Version 3 adds a message and a language tag. Older servers stop
            // after the code, so a missing message is not an error.
            let message = reader.remaining > 0 ? ((try? reader.readString()) ?? "") : ""
            if code == .endOfFile || code == .ok {
                return .status(code, message: message)
            }
            throw SFTPError.remote(code, path: "", detail: message)

        case .handle:
            return .handle(try reader.readData())

        case .data:
            return .data(try reader.readData())

        case .name:
            let count = try reader.readUInt32()
            var names: [(String, String, SFTPAttributes)] = []
            for _ in 0 ..< min(count, 100_000) {
                names.append((
                    try reader.readString(),
                    try reader.readString(),
                    try reader.readAttributes()
                ))
            }
            return .names(names.map { (name: $0.0, longName: $0.1, attributes: $0.2) })

        case .attributes:
            return .attributes(try reader.readAttributes())

        default:
            throw SFTPError.malformedPacket("Unexpected packet type \(type).")
        }
    }

    private func channelClosed() {
        guard !isClosed else { return }
        isClosed = true
        failEveryWaiter(with: SFTPError.channelClosed)
    }

    private func failEveryWaiter(with error: any Error) {
        versionWaiter?.resume(throwing: error)
        versionWaiter = nil
        for continuation in waiting.values { continuation.resume(throwing: error) }
        waiting.removeAll()
    }

    /// Joins a folder and a name without doubling the separator.
    public nonisolated static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty || directory == "." { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
