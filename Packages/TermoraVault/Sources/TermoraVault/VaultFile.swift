//
//  VaultFile.swift
//  TermoraVault
//

import CryptoKit
import Foundation
import TermoraModel

/// The layout of a `.termora` file.
///
/// ```
/// "TERMORA1"          8 bytes, so Finder and `file` can recognise it
/// header length       4 bytes, big-endian
/// header              JSON, plain text
/// body                AES-GCM: nonce, ciphertext, tag
/// ```
///
/// The header is plain text so that a future version can read the key
/// derivation parameters before it asks you for a password. Everything else,
/// including every host name, is inside the sealed body. A Royal TSX document
/// leaves host names readable; this one does not.
public enum VaultFile {
    public static let magic = Data("TERMORA1".utf8)

    /// What the header records. The body holds the `Document`.
    public struct Header: Codable, Hashable, Sendable {
        public var formatVersion: Int
        public var cipher: String
        public var kdf: KDFParameters
    }

    /// Everything a caller needs after opening a file.
    public struct Opened: Sendable {
        public var document: Document
        public var key: SymmetricKey
        public var kdf: KDFParameters
    }

    // MARK: - Writing

    public static func encode(document: Document, key: SymmetricKey, kdf: KDFParameters) throws -> Data {
        let header = Header(
            formatVersion: Document.currentFormatVersion,
            cipher: VaultCrypto.cipherName,
            kdf: kdf
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let headerData = try encoder.encode(header)

        var prefix = magic
        prefix.append(contentsOf: withUnsafeBytes(of: UInt32(headerData.count).bigEndian, Array.init))
        prefix.append(headerData)

        let plaintext = try encoder.encode(document)
        let body = try VaultCrypto.seal(plaintext, key: key, authenticating: prefix)

        var file = prefix
        file.append(body)
        return file
    }

    // MARK: - Reading

    /// Reads the header without needing the password. The unlock sheet uses
    /// this to check the file before it spends half a second on the key.
    public static func readHeader(from file: Data) throws -> (header: Header, authenticatedPrefix: Data, body: Data) {
        guard file.count >= magic.count + 4 else { throw VaultError.truncatedFile }
        guard file.prefix(magic.count) == magic else { throw VaultError.notATermoraDocument }

        let lengthStart = magic.count
        let lengthBytes = file[lengthStart ..< lengthStart + 4]
        let headerLength = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })

        let headerStart = lengthStart + 4
        guard headerLength > 0, file.count >= headerStart + headerLength else {
            throw VaultError.truncatedFile
        }
        let headerData = file[headerStart ..< headerStart + headerLength]

        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: Data(headerData))
        } catch {
            throw VaultError.malformedHeader
        }
        guard header.formatVersion <= Document.currentFormatVersion else {
            throw VaultError.unsupportedFormatVersion(header.formatVersion)
        }
        guard header.cipher == VaultCrypto.cipherName else {
            throw VaultError.unsupportedAlgorithm(header.cipher)
        }

        let body = Data(file[(headerStart + headerLength)...])
        guard !body.isEmpty else { throw VaultError.truncatedFile }

        return (header, Data(file[0 ..< headerStart + headerLength]), body)
    }

    public static func decode(file: Data, password: String) throws -> Opened {
        let parts = try readHeader(from: file)
        let key = try VaultCrypto.deriveKey(password: password, parameters: parts.header.kdf)
        return try decode(file: file, key: key)
    }

    /// Opens a file with a key that is already derived, for example one taken
    /// from the Keychain after Touch ID.
    public static func decode(file: Data, key: SymmetricKey) throws -> Opened {
        let parts = try readHeader(from: file)
        let plaintext = try VaultCrypto.open(parts.body, key: key, authenticating: parts.authenticatedPrefix)
        let document = try JSONDecoder().decode(Document.self, from: plaintext)
        return Opened(document: document, key: key, kdf: parts.header.kdf)
    }
}
