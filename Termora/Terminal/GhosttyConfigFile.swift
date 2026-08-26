//
//  GhosttyConfigFile.swift
//  Termora
//

import Foundation

/// Reads the few keys from a Ghostty configuration file that Termora must act
/// on itself.
///
/// libghostty parses the file for everything else. It cannot resolve a
/// `theme = <name>` line, because the theme files live in the Ghostty
/// application bundle, and Termora is not that bundle. Termora therefore reads
/// that one line and finds the theme in its own catalogue.
enum GhosttyConfigFile {
    /// What a `theme` line asks for.
    ///
    /// Ghostty accepts one name, or a light name and a dark name together.
    struct ThemeChoice: Equatable {
        var light: String
        var dark: String
    }

    /// Reads the last `theme` line in the file.
    ///
    /// The last line wins, the way Ghostty treats a repeated key.
    static func themeChoice(in text: String) -> ThemeChoice? {
        var choice: ThemeChoice?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "theme" else { continue }

            // A leading `?` means "use it if it exists". The name follows.
            var value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("?") { value.removeFirst() }
            if let parsed = split(value) { choice = parsed }
        }
        return choice
    }

    /// True when the file sets the key named at least once.
    static func setsAKey(_ key: String, in text: String) -> Bool {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            if trimmed[..<separator].trimmingCharacters(in: .whitespaces) == key { return true }
        }
        return false
    }

    /// Splits `light:One,dark:Two` into its two names.
    private static func split(_ value: String) -> ThemeChoice? {
        let parts = value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var light: String?
        var dark: String?
        for part in parts {
            let lowered = part.lowercased()
            if lowered.hasPrefix("light:") {
                light = String(part.dropFirst("light:".count)).trimmingCharacters(in: .whitespaces)
            } else if lowered.hasPrefix("dark:") {
                dark = String(part.dropFirst("dark:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let light, let dark { return ThemeChoice(light: light, dark: dark) }

        let name = unquote(value)
        guard !name.isEmpty else { return nil }
        return ThemeChoice(light: name, dark: name)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        for mark in ["\"", "'"] where value.hasPrefix(mark) && value.hasSuffix(mark) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
