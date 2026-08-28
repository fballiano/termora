import CryptoKit
import Foundation
import Testing
@testable import TermoraModel
@testable import TermoraVault

/// Fewer rounds, so the tests stay fast. The real default is 600000.
private let testKDF = KDFParameters(rounds: 2_000, salt: Data(repeating: 7, count: 32))

private func sampleDocument() -> Document {
    let folder = Folder(name: "Prod", settings: NodeSettings(username: .value("root")))
    let connection = Connection(
        parentID: folder.id,
        name: "web-01",
        host: "web01.example.com",
        settings: NodeSettings(authentication: .value(.password(Secret("hunter2"))))
    )
    return Document(folders: [folder], connections: [connection])
}

@Test("A document survives a round trip through the file format")
func fileRoundTrip() throws {
    let key = try VaultCrypto.deriveKey(password: "correct horse", parameters: testKDF)
    let original = sampleDocument()

    let file = try VaultFile.encode(document: original, key: key, kdf: testKDF)
    let opened = try VaultFile.decode(file: file, key: key)

    #expect(opened.document == original)
    #expect(opened.kdf == testKDF)
}

@Test("The wrong password is refused")
func wrongPasswordIsRefused() throws {
    let key = try VaultCrypto.deriveKey(password: "correct horse", parameters: testKDF)
    let file = try VaultFile.encode(document: sampleDocument(), key: key, kdf: testKDF)

    #expect(throws: VaultError.cannotDecrypt) {
        _ = try VaultFile.decode(file: file, password: "wrong horse")
    }
}

@Test("A changed byte in the body is refused")
func tamperedBodyIsRefused() throws {
    let key = try VaultCrypto.deriveKey(password: "correct horse", parameters: testKDF)
    var file = try VaultFile.encode(document: sampleDocument(), key: key, kdf: testKDF)

    file[file.count - 1] ^= 0xFF

    #expect(throws: VaultError.cannotDecrypt) {
        _ = try VaultFile.decode(file: file, key: key)
    }
}

@Test("A changed header is refused, because the header is authenticated")
func tamperedHeaderIsRefused() throws {
    let key = try VaultCrypto.deriveKey(password: "correct horse", parameters: testKDF)
    let file = try VaultFile.encode(document: sampleDocument(), key: key, kdf: testKDF)

    // Lower the round count in the plain text header, as an attacker would.
    var text = String(data: file, encoding: .isoLatin1)!
    text = text.replacingOccurrences(of: "\"rounds\":2000", with: "\"rounds\":1000")
    let changed = text.data(using: .isoLatin1)!
    #expect(changed.count == file.count)

    #expect(throws: VaultError.cannotDecrypt) {
        _ = try VaultFile.decode(file: changed, key: key)
    }
}

@Test("No host name appears in the file")
func hostNamesAreNotReadable() throws {
    let key = try VaultCrypto.deriveKey(password: "correct horse", parameters: testKDF)
    let file = try VaultFile.encode(document: sampleDocument(), key: key, kdf: testKDF)

    #expect(file.range(of: Data("web01.example.com".utf8)) == nil)
    #expect(file.range(of: Data("hunter2".utf8)) == nil)
    #expect(file.range(of: Data("Prod".utf8)) == nil)
}

@Test("A file that is not a Termora document is reported clearly")
func rejectsForeignFiles() {
    #expect(throws: VaultError.notATermoraDocument) {
        _ = try VaultFile.readHeader(from: Data("<?xml version=\"1.0\"?><RTSZDocument>".utf8))
    }
    #expect(throws: VaultError.truncatedFile) {
        _ = try VaultFile.readHeader(from: Data("TERM".utf8))
    }
}

@Test("A cut file is reported as truncated, not as a wrong password")
func truncatedFileIsReported() throws {
    let key = try VaultCrypto.deriveKey(password: "correct horse", parameters: testKDF)
    let file = try VaultFile.encode(document: sampleDocument(), key: key, kdf: testKDF)

    #expect(throws: VaultError.truncatedFile) {
        _ = try VaultFile.readHeader(from: file.prefix(20))
    }
}

@Test("The header can be read without the password")
func headerIsReadableWithoutThePassword() throws {
    let key = try VaultCrypto.deriveKey(password: "correct horse", parameters: testKDF)
    let file = try VaultFile.encode(document: sampleDocument(), key: key, kdf: testKDF)

    let header = try VaultFile.readHeader(from: file).header
    #expect(header.cipher == VaultCrypto.cipherName)
    #expect(header.kdf.rounds == 2_000)
    #expect(header.formatVersion == Document.currentFormatVersion)
}

@Test("Each new salt is different")
func saltsAreRandom() {
    let first = KDFParameters.makeNew(rounds: 1)
    let second = KDFParameters.makeNew(rounds: 1)
    #expect(first.salt != second.salt)
    #expect(first.salt.count == KDFParameters.saltByteCount)
}

@Test("The same password and salt always give the same key")
func derivationIsStable() throws {
    let first = try VaultCrypto.deriveKey(password: "same", parameters: testKDF)
    let second = try VaultCrypto.deriveKey(password: "same", parameters: testKDF)
    #expect(first == second)

    let other = try VaultCrypto.deriveKey(password: "different", parameters: testKDF)
    #expect(first != other)
}

@MainActor
@Test("Saving keeps a backup and never leaves a half written file")
func saveIsAtomicAndKeepsABackup() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("termora-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Connections.termora")

    let vault = try await Vault.create(at: url, password: "first pass", document: sampleDocument())
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(vault.hasUnsavedChanges == false)

    vault.update { $0.add(Folder(name: "Staging")) }
    #expect(vault.hasUnsavedChanges == true)
    try vault.save()
    #expect(vault.hasUnsavedChanges == false)

    // The previous version is kept beside the document.
    #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))

    // No temporary file is left behind.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix(".termora-") }
    #expect(leftovers.isEmpty)

    let reopened = try await Vault.open(at: url, password: "first pass")
    #expect(reopened.document.folders.map(\.name).sorted() == ["Prod", "Staging"])
}

@MainActor
@Test("Changing the master password replaces the salt and the old password stops working")
func changingThePassword() async throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("termora-test-\(UUID().uuidString).termora")
    defer { try? FileManager.default.removeItem(at: url) }

    let vault = try await Vault.create(at: url, password: "old pass", document: sampleDocument())
    let oldSalt = vault.keyMaterial.salt

    try await vault.changePassword(to: "new pass")
    #expect(vault.keyMaterial.salt != oldSalt)

    await #expect(throws: VaultError.cannotDecrypt) {
        _ = try await Vault.open(at: url, password: "old pass")
    }
    let reopened = try await Vault.open(at: url, password: "new pass")
    #expect(reopened.document.connections.map(\.name) == ["web-01"])
}

@MainActor
@Test("After a password change, the backup no longer opens with the old password")
func passwordChangeSealsTheBackupToo() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("termora-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Connections.termora")

    let vault = try await Vault.create(at: url, password: "old pass", document: sampleDocument())
    // A save first, so a backup written with the old key exists.
    vault.update { $0.add(Folder(name: "Staging")) }
    try vault.save()

    try await vault.changePassword(to: "new pass")

    let backup = url.appendingPathExtension("bak")
    #expect(FileManager.default.fileExists(atPath: backup.path),
            "The backup stays: it is resealed, not thrown away.")
    await #expect(throws: VaultError.cannotDecrypt) {
        _ = try await Vault.open(at: backup, password: "old pass")
    }
    let reopened = try await Vault.open(at: backup, password: "new pass")
    #expect(reopened.document.connections.map(\.name) == ["web-01"])
}
