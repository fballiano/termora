//
//  GhosttyFonts.swift
//  Termora
//

import CoreText
import Foundation

/// Makes the font that Ghostty uses by default available to Termora.
///
/// The Ghostty application carries JetBrains Mono inside its own program file,
/// and uses it when your configuration names no font. The `libghostty` library
/// does not carry that font, so without help a pane falls back to another face
/// and looks nothing like your Ghostty window.
///
/// Termora therefore ships the same font and registers it for this process
/// only. Nothing is added to your system font list.
enum GhosttyFonts {
    /// The family name Ghostty uses when a configuration names no font.
    static let defaultFamily = "JetBrains Mono"

    /// Registers the shipped fonts. Safe to call more than once.
    static func register() {
        guard let urls = Bundle.main.urls(
            forResourcesWithExtension: "ttf", subdirectory: nil
        ) else { return }

        for url in urls where url.lastPathComponent.hasPrefix("JetBrainsMono") {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            // A font already registered reports an error. That is not a fault.
            error?.release()
        }
    }

    /// True when this Mac can draw with the family named.
    static func isAvailable(_ family: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
        ] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil)
        return ((matches as? [CTFontDescriptor])?.isEmpty == false)
    }
}
