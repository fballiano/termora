//
//  SFTPBuffer.swift
//  TermoraSFTP
//

import Foundation

/// Writes the SFTP wire types. Everything is big-endian.
struct SFTPWriter {
    private(set) var data = Data()

    mutating func write(_ value: UInt8) {
        data.append(value)
    }

    mutating func write(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// A string is a length and then the bytes. There is no ending zero.
    mutating func write(_ value: String) {
        write(Data(value.utf8))
    }

    mutating func write(_ value: Data) {
        write(UInt32(value.count))
        data.append(value)
    }

    mutating func write(_ attributes: SFTPAttributes) {
        var flags = SFTPAttributeFlags()
        if attributes.size != nil { flags.insert(.size) }
        if attributes.userID != nil, attributes.groupID != nil { flags.insert(.ownership) }
        if attributes.permissions != nil { flags.insert(.permissions) }
        if attributes.accessedAt != nil, attributes.modifiedAt != nil { flags.insert(.times) }

        write(flags.rawValue)
        if let size = attributes.size { write(size) }
        if let user = attributes.userID, let group = attributes.groupID {
            write(user)
            write(group)
        }
        if let permissions = attributes.permissions { write(permissions) }
        if let accessed = attributes.accessedAt, let modified = attributes.modifiedAt {
            write(UInt32(max(0, accessed.timeIntervalSince1970)))
            write(UInt32(max(0, modified.timeIntervalSince1970)))
        }
    }

    /// Wraps the body in the length and type that every packet starts with.
    static func packet(_ type: SFTPPacketType, _ body: (inout SFTPWriter) -> Void) -> Data {
        var writer = SFTPWriter()
        writer.write(type.rawValue)
        body(&writer)

        var framed = SFTPWriter()
        framed.write(UInt32(writer.data.count))
        return framed.data + writer.data
    }
}

/// Reads the SFTP wire types, and refuses to read past the end.
///
/// A far host that sends a short or damaged packet must produce an error, not
/// a crash, so every read checks what is left.
struct SFTPReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func readUInt8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        var value: UInt32 = 0
        for index in 0 ..< 4 { value = (value << 8) | UInt32(data[offset + index]) }
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        try require(8)
        defer { offset += 8 }
        var value: UInt64 = 0
        for index in 0 ..< 8 { value = (value << 8) | UInt64(data[offset + index]) }
        return value
    }

    mutating func readData() throws -> Data {
        let count = Int(try readUInt32())
        try require(count)
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    mutating func readString() throws -> String {
        // A far host may send a name that is not valid UTF-8. Replace the bad
        // bytes rather than fail, so one odd file name cannot hide a folder.
        String(decoding: try readData(), as: UTF8.self)
    }

    mutating func readAttributes() throws -> SFTPAttributes {
        let flags = SFTPAttributeFlags(rawValue: try readUInt32())
        var attributes = SFTPAttributes()

        if flags.contains(.size) { attributes.size = try readUInt64() }
        if flags.contains(.ownership) {
            attributes.userID = try readUInt32()
            attributes.groupID = try readUInt32()
        }
        if flags.contains(.permissions) { attributes.permissions = try readUInt32() }
        if flags.contains(.times) {
            attributes.accessedAt = Date(timeIntervalSince1970: TimeInterval(try readUInt32()))
            attributes.modifiedAt = Date(timeIntervalSince1970: TimeInterval(try readUInt32()))
        }
        if flags.contains(.extended) {
            let count = try readUInt32()
            // Skip what we do not use, but read it properly so the offset
            // stays right for anything after it.
            for _ in 0 ..< min(count, 1024) {
                _ = try readData()
                _ = try readData()
            }
        }
        return attributes
    }

    private func require(_ count: Int) throws {
        guard count >= 0, remaining >= count else {
            throw SFTPError.malformedPacket("The packet ended too early.")
        }
    }
}
