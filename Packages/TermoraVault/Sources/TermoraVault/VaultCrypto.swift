//
//  VaultCrypto.swift
//  TermoraVault
//

import CommonCrypto
import CryptoKit
import Foundation

/// How the master password becomes the encryption key.
///
/// The parameters are written in the plaintext header of the document, so a
/// later version can raise the number of rounds and still open an old file.
/// The header is authenticated, so nobody can lower the rounds of a file you
/// already have.
public struct KDFParameters: Codable, Hashable, Sendable {
    public static let pbkdf2HMACSHA512 = "pbkdf2-hmac-sha512"
    /// Chosen for roughly half a second on Apple silicon in 2026.
    public static let defaultRounds = 600_000
    public static let saltByteCount = 32

    public var algorithm: String
    public var rounds: Int
    public var salt: Data

    public init(algorithm: String = KDFParameters.pbkdf2HMACSHA512,
                rounds: Int = KDFParameters.defaultRounds,
                salt: Data) {
        self.algorithm = algorithm
        self.rounds = rounds
        self.salt = salt
    }

    /// New parameters with a fresh random salt.
    public static func makeNew(rounds: Int = KDFParameters.defaultRounds) -> KDFParameters {
        var salt = Data(count: saltByteCount)
        salt.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, saltByteCount, base)
        }
        return KDFParameters(rounds: rounds, salt: salt)
    }
}

public enum VaultCrypto {
    public static let cipherName = "aes-256-gcm"
    static let keyByteCount = 32

    /// Turns a master password into the document key.
    ///
    /// This step is deliberately slow. Run it away from the main thread and
    /// keep the result, so that saving does not repeat it.
    public static func deriveKey(password: String, parameters: KDFParameters) throws -> SymmetricKey {
        guard parameters.algorithm == KDFParameters.pbkdf2HMACSHA512 else {
            throw VaultError.unsupportedAlgorithm(parameters.algorithm)
        }

        var derived = [UInt8](repeating: 0, count: keyByteCount)
        defer { derived.resetBytes(in: 0 ..< derived.count) }

        var passwordBytes = Array(password.utf8)
        defer { passwordBytes.resetBytes(in: 0 ..< passwordBytes.count) }

        let status: Int32 = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            parameters.salt.withUnsafeBytes { saltBuffer in
                let passwordBase = passwordBuffer.baseAddress.map {
                    UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBase,
                    passwordBuffer.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                    saltBuffer.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                    UInt32(clamping: parameters.rounds),
                    &derived,
                    derived.count
                )
            }
        }

        guard status == kCCSuccess else { throw VaultError.keyDerivationFailed(status) }
        return SymmetricKey(data: derived)
    }

    /// Encrypts the body. The header travels as additional authenticated data,
    /// so a change to the salt or to the number of rounds breaks the seal.
    public static func seal(_ plaintext: Data, key: SymmetricKey, authenticating header: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = box.combined else { throw VaultError.cannotDecrypt }
        return combined
    }

    public static func open(_ body: Data, key: SymmetricKey, authenticating header: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: body)
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw VaultError.cannotDecrypt
        }
    }
}

extension Array where Element == UInt8 {
    /// Overwrites the bytes so a key or a password does not linger in memory.
    mutating func resetBytes(in range: Range<Int>) {
        withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            memset_s(base + range.lowerBound, range.count, 0, range.count)
        }
    }
}
