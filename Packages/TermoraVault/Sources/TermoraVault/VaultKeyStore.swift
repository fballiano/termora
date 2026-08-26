//
//  VaultKeyStore.swift
//  TermoraVault
//

import CryptoKit
import Foundation
import LocalAuthentication

/// Remembers the document key behind Touch ID, using the Secure Enclave.
///
/// This is only a convenience. The document itself never depends on it, so the
/// file still opens with the master password on any machine.
///
/// The Keychain is not used. A Keychain item guarded by Touch ID needs the
/// `keychain-access-groups` entitlement, which macOS only accepts from a build
/// signed with a real team identity. Termora is signed with an ad-hoc
/// signature, so every such call fails with `errSecMissingEntitlement`, and
/// adding the entitlement anyway makes macOS end the process.
///
/// The Secure Enclave has no such rule. Termora asks it for a key that only
/// Touch ID can use, and keeps the sealed record in its own file:
///
/// 1. The Secure Enclave makes a private key that needs Touch ID. Its
///    `dataRepresentation` is a sealed record, useless without that Secure
///    Enclave, so Termora may keep it in a plain file.
/// 2. Termora makes a second key pair, agrees a shared secret with the Secure
///    Enclave public key, and throws its own private half away.
/// 3. The document key is sealed with that shared secret.
///
/// To open it again, only the Secure Enclave can agree the same secret, and it
/// asks for Touch ID first.
///
/// A record is tied to the salt of the document. Changing the master password
/// changes the salt, and the old record then no longer matches.
public enum VaultKeyStore {
    /// What one remembered document needs, all of it safe to keep in a file.
    private struct Record: Codable {
        /// The sealed Secure Enclave key.
        let enclaveKey: Data
        /// The public half of the key pair Termora made and then dropped.
        let publicKey: Data
        /// The document key, sealed with the agreed secret.
        let sealedKey: Data
    }

    private static let purpose = Data("Termora document key".utf8)

    /// True when this Mac can use Touch ID and has a Secure Enclave.
    public static var isBiometryAvailable: Bool {
        SecureEnclave.isAvailable
            && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    // MARK: - Where a record is kept

    /// One file per document and salt.
    static func recordURL(for url: URL, salt: Data) throws -> URL {
        let fingerprint = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8) + salt)
            .map { String(format: "%02x", $0) }.joined()
        return try directory().appendingPathComponent("\(fingerprint).touchid")
    }

    private static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent("Termora/TouchID", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    // MARK: - Keeping and fetching a key

    /// Remembers the key. Returns the reason it could not, or `nil` on success.
    @discardableResult
    public static func store(key: SymmetricKey, salt: Data, for url: URL) -> String? {
        guard SecureEnclave.isAvailable else {
            return "This Mac has no Secure Enclave, so Termora cannot remember the key."
        }
        // `.privateKeyUsage` is not optional here. Without it the rule only
        // guards stored data, and the Secure Enclave refuses to agree a shared
        // secret with the key: "ACL operation is not allowed: 'ock'", where
        // `ock` means Operation Compute Key.
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            nil
        ) else {
            return "Termora could not ask for a key that Touch ID guards."
        }

        do {
            let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: control)
            // A second key pair, used once. Its private half is dropped here,
            // so from now on only the Secure Enclave can agree this secret.
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclave.publicKey)
            let wrapping = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: salt, sharedInfo: purpose, outputByteCount: 32
            )
            let sealed = try AES.GCM.seal(
                key.withUnsafeBytes { Data($0) }, using: wrapping
            ).combined ?? Data()

            let record = Record(
                enclaveKey: enclave.dataRepresentation,
                publicKey: ephemeral.publicKey.rawRepresentation,
                sealedKey: sealed
            )
            let file = try recordURL(for: url, salt: salt)
            try JSONEncoder().encode(record).write(to: file, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// What asking for a remembered key produced.
    public enum Outcome: Sendable {
        case key(SymmetricKey)
        /// Nothing was ever remembered for this document.
        case noRecord
        /// The Secure Enclave refused, with the reason it gave.
        case failed(String)
    }

    /// Asks for the remembered key. macOS shows the Touch ID question here.
    public static func loadKey(salt: Data, for url: URL, reason: String) -> Outcome {
        guard let file = try? recordURL(for: url, salt: salt),
              FileManager.default.fileExists(atPath: file.path)
        else { return .noRecord }

        do {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))

            let context = LAContext()
            context.localizedReason = reason

            let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: record.enclaveKey, authenticationContext: context
            )
            let publicKey = try P256.KeyAgreement.PublicKey(
                rawRepresentation: record.publicKey
            )
            let shared = try enclave.sharedSecretFromKeyAgreement(with: publicKey)
            let wrapping = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: salt, sharedInfo: purpose, outputByteCount: 32
            )
            let box = try AES.GCM.SealedBox(combined: record.sealedKey)
            return .key(SymmetricKey(data: try AES.GCM.open(box, using: wrapping)))
        } catch {
            // A record the Secure Enclave will not use is of no value. Drop
            // it, so the next launch asks for the password once instead of
            // showing the same message for ever.
            if isPermanent(error) { removeKey(salt: salt, for: url) }
            return .failed(describe(error))
        }
    }

    /// True when trying the same record again would fail the same way.
    private static func isPermanent(_ error: any Error) -> Bool {
        let text = String(describing: error)
        if (error as NSError).code == -128 || text.contains("UserCancel") { return false }
        return true
    }

    /// Turns a Secure Enclave error into words a person can act on.
    private static func describe(_ error: any Error) -> String {
        let text = String(describing: error)
        let code = (error as NSError).code

        if code == -128 || text.contains("UserCancel") {
            return "You stopped the Touch ID question."
        }
        // A record made by an older version of Termora may carry a rule that
        // the Secure Enclave will not use for this step.
        if text.contains("'ock'") || text.contains("ACL operation is not allowed") {
            return "The remembered key was made with a rule that the Secure "
                + "Enclave will not accept. Unlock with the master password and "
                + "tick the box again to make a new one."
        }
        return text
    }

    /// True when a record exists, without asking for Touch ID. The unlock
    /// screen uses this to decide whether to offer the Touch ID button.
    public static func hasKey(salt: Data, for url: URL) -> Bool {
        guard let file = try? recordURL(for: url, salt: salt) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    public static func removeKey(salt: Data, for url: URL) {
        guard let file = try? recordURL(for: url, salt: salt) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
