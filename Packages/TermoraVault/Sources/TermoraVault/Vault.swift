//
//  Vault.swift
//  TermoraVault
//

import CryptoKit
import Foundation
import TermoraModel

/// One open document.
///
/// The vault keeps the derived key, so saving is fast. Deriving the key is
/// slow on purpose, and `open` and `create` run it away from the main thread.
@MainActor
public final class Vault {
    public private(set) var url: URL
    public private(set) var document: Document
    public private(set) var hasUnsavedChanges = false

    private var key: SymmetricKey
    private var kdf: KDFParameters

    private init(url: URL, document: Document, key: SymmetricKey, kdf: KDFParameters) {
        self.url = url
        self.document = document
        self.key = key
        self.kdf = kdf
    }

    // MARK: - Opening and creating

    /// Opens a document with a master password.
    public static func open(at url: URL, password: String) async throws -> Vault {
        let file = try Data(contentsOf: url)
        let opened = try await derive { try VaultFile.decode(file: file, password: password) }
        return Vault(url: url, document: opened.document, key: opened.key, kdf: opened.kdf)
    }

    /// Opens a document with a key taken from the Keychain after Touch ID.
    public static func open(at url: URL, key: SymmetricKey) throws -> Vault {
        let file = try Data(contentsOf: url)
        let opened = try VaultFile.decode(file: file, key: key)
        return Vault(url: url, document: opened.document, key: opened.key, kdf: opened.kdf)
    }

    /// Creates a new document and writes it at once, so the file exists before
    /// you add anything to it.
    public static func create(
        at url: URL,
        password: String,
        document: Document = .empty
    ) async throws -> Vault {
        let kdf = KDFParameters.makeNew()
        let key = try await derive { try VaultCrypto.deriveKey(password: password, parameters: kdf) }
        let vault = Vault(url: url, document: document, key: key, kdf: kdf)
        try vault.save()
        return vault
    }

    /// Reads the header of a file without a password, to check that Termora
    /// can open it at all.
    public nonisolated static func inspect(at url: URL) throws -> VaultFile.Header {
        try VaultFile.readHeader(from: Data(contentsOf: url)).header
    }

    // MARK: - Changes

    /// Changes the document and marks it unsaved.
    public func update(_ change: (inout Document) -> Void) {
        change(&document)
        hasUnsavedChanges = true
    }

    /// Writes the document.
    ///
    /// The old file is copied to `<name>.bak` first, then the new file is
    /// written beside the target and swapped in. A crash during the write
    /// therefore leaves either the old file or the new one, never half of one.
    public func save() throws {
        let data = try VaultFile.encode(document: document, key: key, kdf: kdf)
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? fileManager.removeItem(at: backup)
            try? fileManager.copyItem(at: url, to: backup)
        }

        let temporary = directory.appendingPathComponent(".termora-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        hasUnsavedChanges = false
    }

    /// Saves the document under a new name and continues with the new file.
    public func save(to newURL: URL) throws {
        url = newURL
        try save()
    }

    /// Replaces the master password. The salt changes too, so any key held in
    /// the Keychain for this document stops matching and must be stored again.
    public func changePassword(to newPassword: String) async throws {
        let newKDF = KDFParameters.makeNew()
        let newKey = try await Self.derive {
            try VaultCrypto.deriveKey(password: newPassword, parameters: newKDF)
        }
        kdf = newKDF
        key = newKey
        try save()
    }

    /// The key and the salt, for the Keychain cache.
    public var keyMaterial: (key: SymmetricKey, salt: Data) { (key, kdf.salt) }

    /// Runs the slow key derivation off the main thread.
    private static func derive<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }
}
