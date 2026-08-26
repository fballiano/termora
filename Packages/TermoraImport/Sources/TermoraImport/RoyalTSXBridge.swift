//
//  RoyalTSXBridge.swift
//  TermoraImport
//

import Foundation

/// Asks Royal TSX for the secrets it holds.
///
/// Royal TSX encrypts `CredentialPassword` and `CredentialPassphrase` inside
/// the document with a scheme it does not publish. Rather than guess at it,
/// Termora asks Royal TSX itself: the application has an AppleScript
/// dictionary with a `get property value` command that takes a key name and an
/// object ID, and it answers with the decrypted value.
///
/// This needs Royal TSX installed, and macOS asks you once for permission to
/// control it. When anything fails, the import still runs and the report names
/// every entry whose secret you must type in.
///
/// The type is bound to the main actor on purpose. `NSAppleScript` needs the
/// main thread and a run loop; calling it from anywhere else does not fail,
/// it simply never returns. Binding the type turns that hang into a compiler
/// error instead of a mystery.
@MainActor
public struct RoyalTSXBridge: Sendable {
    public enum Availability: Sendable, Equatable {
        case ready
        case notInstalled
        /// macOS refused the automation permission.
        case permissionRefused
        case failed(String)
    }

    nonisolated public static let applicationName = "Royal TSX"

    public init() {}

    nonisolated public static var isInstalled: Bool {
        NSWorkspace_applicationURL() != nil
    }

    /// Starts Royal TSX and opens the document, so that later questions have
    /// something to answer about.
    ///
    /// Royal TSX needs a moment after it opens a document before it can answer.
    /// The wait is inside the script, so the application is idle rather than
    /// busy while it passes.
    @discardableResult
    public func openDocument(path: String) -> Availability {
        guard Self.isInstalled else { return .notInstalled }
        if let error = run(script: openDocumentScript(path: path)).error {
            return classify(error)
        }
        return .ready
    }

    /// Reads one property. An empty answer means Royal TSX has nothing, or
    /// would not say.
    public func value(ofKey key: String, objectID: String) -> String {
        let outcome = run(script: Self.script(forKey: key, objectID: objectID))
        guard outcome.error == nil else { return "" }
        return outcome.value
    }

    /// The script that asks for one property.
    ///
    /// Separated from running it so the quoting can be tested. A Royal object
    /// ID is a plain identifier, but a key name or a path must never be able
    /// to end the string and add commands of its own.
    nonisolated static func script(forKey key: String, objectID: String) -> String {
        """
        tell application "\(applicationName)"
            get property value of key "\(escape(key))" from id "\(escape(objectID))"
        end tell
        """
    }

    /// How long to let Royal TSX settle after it opens a document.
    nonisolated static let settleSeconds = 2

    nonisolated static func openDocumentScript(path: String) -> String {
        """
        tell application "\(applicationName)"
            open document "\(escape(path))"
            delay \(settleSeconds)
        end tell
        """
    }

    private func openDocumentScript(path: String) -> String {
        Self.openDocumentScript(path: path)
    }

    /// AppleScript strings use backslash escaping, the same as Swift.
    nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func classify(_ error: String) -> Availability {
        let lowered = error.lowercased()
        if lowered.contains("not allowed") || lowered.contains("-1743")
            || lowered.contains("not authorised") || lowered.contains("not authorized") {
            return .permissionRefused
        }
        return .failed(error)
    }

    private func run(script source: String) -> (value: String, error: String?) {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return ("", "Termora could not build the script.")
        }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            return ("", number.map { "\(message) (\($0))" } ?? message)
        }
        return (descriptor.stringValue ?? "", nil)
    }
}

#if canImport(AppKit)
    import AppKit

    private func NSWorkspace_applicationURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.codeplex.RoyalTSX")
            ?? [URL(fileURLWithPath: "/Applications/Royal TSX.app")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
#else
    private func NSWorkspace_applicationURL() -> URL? { nil }
#endif
