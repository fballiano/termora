//
//  SFTPError.swift
//  TermoraSFTP
//

import Foundation

public enum SFTPError: Error, LocalizedError, Equatable {
    /// The far host answered with a failure.
    case remote(SFTPStatusCode, path: String, detail: String)
    case malformedPacket(String)
    /// The far host speaks a version this client does not.
    case unsupportedVersion(UInt32)
    case channelClosed
    case timedOut(String)
    case cannotReadLocalFile(String)

    public var errorDescription: String? {
        switch self {
        case let .remote(code, path, detail):
            let where_ = path.isEmpty ? "" : " (\(path))"
            return detail.isEmpty
                ? code.describedForPerson + where_
                : "\(code.describedForPerson)\(where_) \(detail)"
        case let .malformedPacket(detail):
            return "The far host sent something this client could not read. \(detail)"
        case let .unsupportedVersion(version):
            return "The far host speaks SFTP version \(version). Termora speaks version 3."
        case .channelClosed:
            return "The SFTP channel closed."
        case let .timedOut(what):
            return "The far host did not answer. \(what)"
        case let .cannotReadLocalFile(path):
            return "Termora could not read \(path)."
        }
    }

    /// True when the far host simply reported the end of a listing or a file.
    var isEndOfFile: Bool {
        if case let .remote(code, _, _) = self { return code == .endOfFile }
        return false
    }
}
