//
//  VaultError.swift
//  TermoraVault
//

import Foundation

public enum VaultError: Error, Equatable, LocalizedError {
    /// The file does not start with the Termora magic bytes.
    case notATermoraDocument
    /// The file stops before the header or the body is complete.
    case truncatedFile
    /// The file was written by a newer version of Termora.
    case unsupportedFormatVersion(Int)
    /// The header names a cipher or a key derivation function we do not have.
    case unsupportedAlgorithm(String)
    /// The password is wrong, or the file was changed after it was written.
    case cannotDecrypt
    /// The key derivation function failed. The number is the system code.
    case keyDerivationFailed(Int32)
    /// The header is not valid JSON.
    case malformedHeader

    public var errorDescription: String? {
        switch self {
        case .notATermoraDocument:
            "This file is not a Termora document."
        case .truncatedFile:
            "This document is incomplete. Try the .bak file next to it."
        case let .unsupportedFormatVersion(version):
            "This document uses format version \(version). Update Termora to open it."
        case let .unsupportedAlgorithm(name):
            "This document uses an algorithm this version does not have: \(name)."
        case .cannotDecrypt:
            "The password is wrong, or the document was changed after it was saved."
        case let .keyDerivationFailed(code):
            "The system could not derive the key. Code \(code)."
        case .malformedHeader:
            "The header of this document is damaged."
        }
    }
}
