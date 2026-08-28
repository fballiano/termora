//
//  AppSettings.swift
//  Termora
//

import Foundation
import TermoraModel

/// The application-wide settings, kept in `UserDefaults`.
///
/// None of these is a secret, and none belongs to one document. A value that
/// belongs to a connection lives in the document, where the inheritance
/// system handles it.
enum AppSettings {
    static let confirmQuitKey = "TermoraConfirmQuit"
    static let openLastDocumentKey = "TermoraOpenLastDocumentAtLaunch"
    static let autoLockMinutesKey = "TermoraAutoLockMinutes"
    static let lockOnSleepKey = "TermoraLockOnSleep"
    static let defaultHostKeyPolicyKey = "TermoraDefaultHostKeyPolicy"
    static let defaultKeepAliveKey = "TermoraDefaultKeepAliveSeconds"
    static let connectTimeoutKey = "TermoraConnectTimeoutSeconds"
    /// The application that opens a remote file for editing. Empty means the
    /// default application for the file's type.
    static let remoteEditorPathKey = "TermoraRemoteEditorPath"

    /// The value each setting has until a person changes it. Registering
    /// keeps `@AppStorage` in the Settings window and the readers below on
    /// the same defaults.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            confirmQuitKey: true,
            openLastDocumentKey: true,
            autoLockMinutesKey: 0,
            lockOnSleepKey: false,
            defaultHostKeyPolicyKey: HostKeyPolicy.ask.rawValue,
            defaultKeepAliveKey: EffectiveSettings.fallback.keepAliveSeconds,
            connectTimeoutKey: 180,
        ])
    }

    /// Ask before ⌘Q closes open sessions.
    static var confirmQuit: Bool {
        UserDefaults.standard.bool(forKey: confirmQuitKey)
    }

    static var opensLastDocumentAtLaunch: Bool {
        UserDefaults.standard.bool(forKey: openLastDocumentKey)
    }

    /// Minutes without use before the document locks. Zero turns it off.
    static var autoLockMinutes: Int {
        UserDefaults.standard.integer(forKey: autoLockMinutesKey)
    }

    static var locksOnSleep: Bool {
        UserDefaults.standard.bool(forKey: lockOnSleepKey)
    }

    /// Seconds a new connection may wait for authentication. The floor keeps
    /// a stray value from cutting a connection off before a person can type.
    static var connectTimeoutSeconds: Int {
        max(10, UserDefaults.standard.integer(forKey: connectTimeoutKey))
    }

    /// The chosen editor application, when one is set and still installed.
    static var remoteEditorURL: URL? {
        let path = UserDefaults.standard.string(forKey: remoteEditorPathKey) ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The values a connection uses when no folder or bookmark sets one.
    static var connectionFallback: EffectiveSettings {
        var fallback = EffectiveSettings.fallback
        fallback.hostKeyPolicy = HostKeyPolicy(
            rawValue: UserDefaults.standard.string(forKey: defaultHostKeyPolicyKey) ?? ""
        ) ?? .ask
        fallback.keepAliveSeconds = max(
            0, UserDefaults.standard.integer(forKey: defaultKeepAliveKey)
        )
        return fallback
    }
}
