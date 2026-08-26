//
//  SFTPTypes.swift
//  TermoraSFTP
//
//  The names and numbers come from draft-ietf-secsh-filexfer-02, which is
//  SFTP version 3. Every OpenSSH server speaks it.
//

import Foundation

enum SFTPPacketType: UInt8 {
    case initialise = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20

    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attributes = 105
}

/// Flags for `open`.
struct SFTPOpenFlags: OptionSet {
    let rawValue: UInt32
    static let read = SFTPOpenFlags(rawValue: 0x0000_0001)
    static let write = SFTPOpenFlags(rawValue: 0x0000_0002)
    static let append = SFTPOpenFlags(rawValue: 0x0000_0004)
    static let create = SFTPOpenFlags(rawValue: 0x0000_0008)
    static let truncate = SFTPOpenFlags(rawValue: 0x0000_0010)
    static let exclusive = SFTPOpenFlags(rawValue: 0x0000_0020)
}

/// Which fields an attributes block carries.
struct SFTPAttributeFlags: OptionSet {
    let rawValue: UInt32
    static let size = SFTPAttributeFlags(rawValue: 0x0000_0001)
    static let ownership = SFTPAttributeFlags(rawValue: 0x0000_0002)
    static let permissions = SFTPAttributeFlags(rawValue: 0x0000_0004)
    static let times = SFTPAttributeFlags(rawValue: 0x0000_0008)
    static let extended = SFTPAttributeFlags(rawValue: 0x8000_0000)
}

/// The result code in a status packet.
public enum SFTPStatusCode: UInt32, Sendable {
    case ok = 0
    case endOfFile = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
    case badMessage = 5
    case noConnection = 6
    case connectionLost = 7
    case operationUnsupported = 8

    public var describedForPerson: String {
        switch self {
        case .ok: "Everything worked."
        case .endOfFile: "The end of the file."
        case .noSuchFile: "There is no such file or folder."
        case .permissionDenied: "You are not allowed to do that."
        case .failure: "The far host refused."
        case .badMessage: "The far host did not understand the request."
        case .noConnection: "There is no connection."
        case .connectionLost: "The connection was lost."
        case .operationUnsupported: "The far host does not support that."
        }
    }
}

/// What a file or folder looks like.
public struct SFTPAttributes: Hashable, Sendable {
    public var size: UInt64?
    public var userID: UInt32?
    public var groupID: UInt32?
    /// The POSIX mode, including the file type bits.
    public var permissions: UInt32?
    public var accessedAt: Date?
    public var modifiedAt: Date?

    public init(size: UInt64? = nil, userID: UInt32? = nil, groupID: UInt32? = nil,
                permissions: UInt32? = nil, accessedAt: Date? = nil, modifiedAt: Date? = nil) {
        self.size = size
        self.userID = userID
        self.groupID = groupID
        self.permissions = permissions
        self.accessedAt = accessedAt
        self.modifiedAt = modifiedAt
    }

    // The file type lives in the top bits of the POSIX mode.
    private var fileTypeBits: UInt32? { permissions.map { $0 & 0xF000 } }

    public var isDirectory: Bool { fileTypeBits == 0x4000 }
    public var isSymbolicLink: Bool { fileTypeBits == 0xA000 }
    public var isRegularFile: Bool { fileTypeBits == 0x8000 }

    /// `rwxr-xr-x`, or an empty string when the far host said nothing.
    public var permissionsText: String {
        guard let permissions else { return "" }
        let flags = ["x", "w", "r"]
        var text = ""
        for group in stride(from: 6, through: 0, by: -3) {
            for bit in stride(from: 2, through: 0, by: -1) {
                let isSet = permissions & (1 << UInt32(group + bit)) != 0
                text += isSet ? flags[bit] : "-"
            }
        }
        return text
    }
}

/// One entry in a directory listing.
public struct SFTPEntry: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let name: String
    /// The full path, so the browser never has to join strings itself.
    public let path: String
    /// The line the far host would print in `ls -l`, when it sends one.
    public let longName: String
    public let attributes: SFTPAttributes

    public var isDirectory: Bool { attributes.isDirectory }
    public var isSymbolicLink: Bool { attributes.isSymbolicLink }
    public var size: UInt64 { attributes.size ?? 0 }
    public var modifiedAt: Date? { attributes.modifiedAt }

    /// `.` and `..` are never shown in the browser.
    public var isCurrentOrParent: Bool { name == "." || name == ".." }

    public init(name: String, path: String, longName: String, attributes: SFTPAttributes) {
        self.name = name
        self.path = path
        self.longName = longName
        self.attributes = attributes
    }
}
