//
//  VaultKeyStoreTests.swift
//  TermoraVaultTests
//

import CryptoKit
import Foundation
import Testing
@testable import TermoraVault

/// Checks the part of the Touch ID store that needs no Touch ID.
///
/// Fetching a key asks for a fingerprint, so no test does that. A person must
/// try that step by hand.
@Suite("Touch ID store")
struct VaultKeyStoreTests {
    private func document(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/termora-tests/\(name).termora")
    }

    @Test("A record belongs to one document and one salt")
    func recordsAreSeparate() throws {
        let saltA = Data(repeating: 1, count: 32)
        let saltB = Data(repeating: 2, count: 32)

        let one = try VaultKeyStore.recordURL(for: document("one"), salt: saltA)
        let two = try VaultKeyStore.recordURL(for: document("two"), salt: saltA)
        let three = try VaultKeyStore.recordURL(for: document("one"), salt: saltB)

        #expect(one != two, "Two documents must not share a record.")
        #expect(one != three, "A new master password must not open the old record.")
        #expect(try VaultKeyStore.recordURL(for: document("one"), salt: saltA) == one,
                "The same document and salt must always name the same record.")
    }

    @Test("A key is remembered and can be forgotten")
    func remembersAndForgets() throws {
        try #require(SecureEnclave.isAvailable, "This Mac has no Secure Enclave.")

        let url = document("remember-\(UUID().uuidString)")
        let salt = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
        defer { VaultKeyStore.removeKey(salt: salt, for: url) }

        #expect(!VaultKeyStore.hasKey(salt: salt, for: url),
                "Nothing is remembered before it is asked for.")

        let problem = VaultKeyStore.store(key: SymmetricKey(size: .bits256),
                                          salt: salt, for: url)
        #expect(problem == nil, "Remembering must work: \(problem ?? "")")
        #expect(VaultKeyStore.hasKey(salt: salt, for: url))

        VaultKeyStore.removeKey(salt: salt, for: url)
        #expect(!VaultKeyStore.hasKey(salt: salt, for: url))
    }

    @Test("The record keeps no key that a reader could use")
    func theRecordHoldsNothingPlain() throws {
        try #require(SecureEnclave.isAvailable, "This Mac has no Secure Enclave.")

        let url = document("secrecy-\(UUID().uuidString)")
        let salt = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
        defer { VaultKeyStore.removeKey(salt: salt, for: url) }

        let key = SymmetricKey(size: .bits256)
        #expect(VaultKeyStore.store(key: key, salt: salt, for: url) == nil)

        let file = try VaultKeyStore.recordURL(for: url, salt: salt)
        let written = try Data(contentsOf: file)
        let raw = key.withUnsafeBytes { Data($0) }
        #expect(written.range(of: raw) == nil,
                "The document key must never appear in the record.")

        // The file must not be readable by anyone else on this Mac.
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o600)
    }
}
