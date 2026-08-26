//
//  AskpassPrompt.swift
//  TermoraSSH
//

import Foundation

/// What OpenSSH is asking for.
///
/// `SSH_ASKPASS_REQUIRE=force` sends every question to the helper, so Termora
/// must read the text to know which one it is. The text comes from OpenSSH
/// and is in English whatever the language of the Mac.
public enum AskpassPrompt: Hashable, Sendable {
    /// The account password on the far host.
    case password
    /// The passphrase that unlocks a private key file.
    case keyPassphrase(keyPath: String)
    /// The host key is unknown or has changed. The answer is `yes` or `no`.
    case hostKey(details: String)
    /// Something else. Show the text and let the person answer.
    case other(text: String)

    /// Reads the prompt text that OpenSSH passes as the first argument.
    public static func classify(_ text: String) -> AskpassPrompt {
        let lowered = text.lowercased()

        // Order matters. A host key question also contains the word "key",
        // and a passphrase question also contains the word "phrase".
        if lowered.contains("continue connecting")
            || lowered.contains("host key verification")
            || lowered.contains("key fingerprint")
            || (lowered.contains("authenticity of host") && lowered.contains("established")) {
            return .hostKey(details: text)
        }
        if lowered.contains("passphrase for key") || lowered.contains("enter passphrase") {
            return .keyPassphrase(keyPath: extractQuotedPath(from: text) ?? "")
        }
        if lowered.contains("password") {
            return .password
        }
        return .other(text: text)
    }

    /// Pulls `/Users/fab/.ssh/id_ed25519` out of
    /// `Enter passphrase for key '/Users/fab/.ssh/id_ed25519':`.
    private static func extractQuotedPath(from text: String) -> String? {
        guard let start = text.firstIndex(of: "'") else { return nil }
        let rest = text[text.index(after: start)...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }
}

/// One question from one connection attempt.
public struct AskpassRequest: Sendable {
    /// The random token Termora gave to this connection attempt.
    public let sessionToken: String
    public let rawText: String
    public let prompt: AskpassPrompt

    public init(sessionToken: String, rawText: String) {
        self.sessionToken = sessionToken
        self.rawText = rawText
        prompt = AskpassPrompt.classify(rawText)
    }
}
