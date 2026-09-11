//
//  GhosttyEnvironment.swift
//  Termora
//

import Foundation
import GhosttyTerminal
import GhosttyTheme
import TermoraSSH

/// The single Ghostty runtime for the whole application.
///
/// libghostty keeps one application object, so every pane shares one
/// controller and therefore one parsed configuration. This type is the only
/// place that decides which configuration file Ghostty reads.
@MainActor
enum GhosttyEnvironment {
    static let controller = TerminalController(
        configSource: userConfigSource(),
        // The theme your own configuration file names. With nothing here the
        // package puts its own colours over everything, and a pane looks
        // nothing like the Ghostty window you use every day.
        theme: userTheme(),
        terminalConfiguration: userConfiguration()
    )

    /// The name every pane announces as `TERM`.
    ///
    /// libghostty exports this name to the program it runs. Termora never
    /// changes it for a local pane: a pane on this Mac reads the description
    /// from the application bundle and works.
    static let terminalName = "xterm-ghostty"

    /// The terminal of a pane, and where its description lives.
    ///
    /// The description ships inside Termora, so a Mac without the Ghostty
    /// application can still send it to a server.
    static var localTerminal: LocalTerminal {
        LocalTerminal(
            name: terminalName,
            databasePath: GhosttyRuntimeResources.terminfoDirectoryURL?.path
        )
    }

    /// The settings Termora adds on top of your own configuration file.
    ///
    /// Every one of these is a value that Ghostty itself uses when a
    /// configuration file says nothing. `libghostty` on its own does not
    /// always reach the same value, so Termora names them. A key that your own
    /// file sets is never touched: your file always wins.
    ///
    /// - `font-family`: Ghostty carries JetBrains Mono inside its own program
    ///   file. `libghostty` does not, so Termora ships the same font and names
    ///   it. See `GhosttyFonts`.
    /// - `font-size`: Ghostty uses 13.
    /// - `font-thicken`: Ghostty leaves this off. Thickening makes every
    ///   stroke heavier, which is plain on a light theme.
    /// - `keybind`: see `menuKeyTriggers`.
    static func userConfiguration() -> TerminalConfiguration {
        GhosttyFonts.register()

        var text = ""
        if case let .file(path) = userConfigSource() {
            text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }

        var configuration = TerminalConfiguration()
        if !GhosttyConfigFile.setsAKey("font-family", in: text),
           GhosttyFonts.isAvailable(GhosttyFonts.defaultFamily) {
            configuration = configuration.fontFamily(GhosttyFonts.defaultFamily)
        }
        if !GhosttyConfigFile.setsAKey("font-size", in: text) {
            configuration = configuration.fontSize(ghosttyFontSize)
        }
        if !GhosttyConfigFile.setsAKey("font-thicken", in: text) {
            configuration = configuration.fontThicken(false)
        }

        let yours = GhosttyConfigFile.boundTriggers(in: text)
        for trigger in menuKeyTriggers where !yours.contains(trigger) {
            configuration = configuration.custom("keybind", "\(trigger)=unbind")
        }
        return configuration
    }

    /// The key presses that belong to Termora's menus, not to a pane.
    ///
    /// A pane answers a key before the menu bar sees it: AppKit offers a key
    /// equivalent to the views of the key window first, and the Ghostty view
    /// takes every key that Ghostty binds. Ghostty binds ⌘1…⌘9 to `goto_tab`,
    /// ⌘⇧[ and ⌘⇧] to its own tabs, ⌘D to a split, and more. Termora has no
    /// tabs or splits inside a pane, so it drops those actions: the key press
    /// was eaten, the menu never ran, and nothing happened at all.
    ///
    /// Each trigger below is unbound in the pane, so the menu item answers it.
    /// A trigger your own configuration file binds is left alone, the way
    /// every other key in this file is.
    ///
    /// ⌘W is not in the list on purpose. Ghostty must keep it: closing a pane
    /// with a program still in it asks you first, and only Ghostty knows that
    /// the program is there.
    ///
    /// Ghostty binds a digit twice, as the character and as the key in that
    /// position, so that a keyboard with digits on shifted keys still works.
    /// Both forms are unbound.
    static let menuKeyTriggers: [String] = {
        let digitKeyNames = [
            "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        ]
        var triggers: [String] = []
        for (index, name) in digitKeyNames.enumerated() {
            triggers.append("super+\(index + 1)")
            triggers.append("super+physical:\(name)")
        }
        triggers += [
            "super+shift+[",  // Session, Previous Tab
            "super+shift+]",  // Session, Next Tab
            "super+d",        // Session, Split Right
            "super+shift+d",  // Session, Split Down
            "super+enter",    // Session, Connect
            "super+shift+f",  // Session, Browse Files
            "super+n",        // File, New Connection
            "super+shift+w",  // File, Close Window
            "super+,",        // Termora, Settings…
        ]
        return triggers
    }()

    /// The font size Ghostty uses when a configuration file names none.
    static let ghosttyFontSize: Float = 13

    /// Builds the theme that the `theme` line of your Ghostty file names.
    ///
    /// libghostty cannot do this itself. It reads theme files from the Ghostty
    /// application bundle, and Termora is a different bundle. The theme
    /// catalogue that ships with the package holds the same themes, so Termora
    /// looks the name up there.
    static func userTheme() -> TerminalTheme {
        guard case let .file(path) = userConfigSource(),
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let choice = GhosttyConfigFile.themeChoice(in: text)
        else { return TerminalTheme() }

        let light = GhosttyThemeCatalog.theme(named: choice.light)?.toTerminalConfiguration()
        let dark = GhosttyThemeCatalog.theme(named: choice.dark)?.toTerminalConfiguration()
        return TerminalTheme(light: light ?? .init(), dark: dark ?? .init())
    }

    /// The configuration file that Ghostty itself would read.
    ///
    /// Termora reads the same file, so a pane looks exactly like your normal
    /// Ghostty window. Termora never writes to this file.
    static func userConfigSource() -> TerminalController.ConfigSource {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            candidates.append(URL(fileURLWithPath: xdg).appending(path: "ghostty/config"))
        }
        let home = fileManager.homeDirectoryForCurrentUser
        candidates.append(home.appending(path: ".config/ghostty/config"))
        candidates.append(home.appending(path: "Library/Application Support/com.mitchellh.ghostty/config"))

        for url in candidates where fileManager.fileExists(atPath: url.path) {
            return .file(url.path)
        }
        return .none
    }
}
