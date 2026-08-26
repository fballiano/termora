import Foundation
import Testing
@testable import TermoraSFTP

@Test("Every wire type survives a round trip, big-endian")
func wireRoundTrip() throws {
    var writer = SFTPWriter()
    writer.write(UInt8(7))
    writer.write(UInt32(0x1234_5678))
    writer.write(UInt64(0x0102_0304_0506_0708))
    writer.write("hello")
    writer.write(Data([0xDE, 0xAD]))

    var reader = SFTPReader(writer.data)
    #expect(try reader.readUInt8() == 7)
    #expect(try reader.readUInt32() == 0x1234_5678)
    #expect(try reader.readUInt64() == 0x0102_0304_0506_0708)
    #expect(try reader.readString() == "hello")
    #expect(try reader.readData() == Data([0xDE, 0xAD]))
    #expect(reader.remaining == 0)
}

@Test("Numbers are written most significant byte first")
func numbersAreBigEndian() {
    var writer = SFTPWriter()
    writer.write(UInt32(1))
    #expect(Array(writer.data) == [0, 0, 0, 1])
}

@Test("A packet carries its length and its type")
func packetFraming() throws {
    // This is the very first packet a client sends.
    let packet = SFTPWriter.packet(.initialise) { $0.write(SFTPClient.version) }
    #expect(Array(packet) == [0, 0, 0, 5, 1, 0, 0, 0, 3])

    var reader = SFTPReader(packet)
    #expect(try reader.readUInt32() == 5, "The length counts everything after itself.")
    #expect(try reader.readUInt8() == SFTPPacketType.initialise.rawValue)
    #expect(try reader.readUInt32() == 3)
}

@Test("A packet that ends too early is refused instead of crashing")
func refusesShortPackets() {
    var reader = SFTPReader(Data([0, 0]))
    #expect(throws: SFTPError.self) { _ = try reader.readUInt32() }

    // A string that claims more bytes than the packet holds.
    var lying = SFTPReader(Data([0, 0, 0, 200, 0x61]))
    #expect(throws: SFTPError.self) { _ = try lying.readString() }

    var empty = SFTPReader(Data())
    #expect(throws: SFTPError.self) { _ = try empty.readUInt8() }
}

@Test("Attributes carry only the fields the flags announce")
func attributesRoundTrip() throws {
    let original = SFTPAttributes(
        size: 4096,
        userID: 501,
        groupID: 20,
        permissions: 0o100_644,
        accessedAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    var writer = SFTPWriter()
    writer.write(original)

    var reader = SFTPReader(writer.data)
    let restored = try reader.readAttributes()
    #expect(restored.size == 4096)
    #expect(restored.userID == 501)
    #expect(restored.permissions == 0o100_644)
    #expect(restored.modifiedAt == original.modifiedAt)
    #expect(reader.remaining == 0)

    // An empty set writes only the flags.
    var bare = SFTPWriter()
    bare.write(SFTPAttributes())
    #expect(Array(bare.data) == [0, 0, 0, 0])
}

@Test("The file type is read out of the POSIX mode")
func readsFileType() {
    #expect(SFTPAttributes(permissions: 0o040_755).isDirectory)
    #expect(SFTPAttributes(permissions: 0o100_644).isRegularFile)
    #expect(SFTPAttributes(permissions: 0o120_777).isSymbolicLink)
    #expect(!SFTPAttributes(permissions: 0o100_644).isDirectory)
    // A far host that says nothing must not be called a folder.
    #expect(!SFTPAttributes().isDirectory)
}

@Test("Permissions are shown the way ls shows them")
func permissionText() {
    #expect(SFTPAttributes(permissions: 0o100_644).permissionsText == "rw-r--r--")
    #expect(SFTPAttributes(permissions: 0o040_755).permissionsText == "rwxr-xr-x")
    #expect(SFTPAttributes(permissions: 0o100_000).permissionsText == "---------")
    #expect(SFTPAttributes().permissionsText.isEmpty)
}

@Test("Joining a folder and a name never doubles the separator")
func joinsPaths() {
    #expect(SFTPClient.join("/var/log", "system.log") == "/var/log/system.log")
    #expect(SFTPClient.join("/var/log/", "system.log") == "/var/log/system.log")
    #expect(SFTPClient.join("/", "etc") == "/etc")
    #expect(SFTPClient.join(".", "file") == "file")
    #expect(SFTPClient.join("", "file") == "file")
}

@Test("A name that is not valid UTF-8 does not hide the rest of the folder")
func toleratesBadNames() throws {
    var writer = SFTPWriter()
    writer.write(Data([0xFF, 0xFE, 0x61]))

    var reader = SFTPReader(writer.data)
    let name = try reader.readString()
    #expect(!name.isEmpty, "Bad bytes are replaced, not thrown away.")
}
