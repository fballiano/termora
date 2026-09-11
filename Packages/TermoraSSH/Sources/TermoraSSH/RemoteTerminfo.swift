//
//  RemoteTerminfo.swift
//  TermoraSSH
//

import CryptoKit
import Foundation

/// The terminal that Termora draws with, as the far end must know it.
///
/// Termora uses the Ghostty engine, and Ghostty calls itself `xterm-ghostty`.
/// Almost no server holds that description, so `htop`, `vim`, and `less` stop
/// with "Error opening terminal". Termora can put the description on the
/// server itself, over the connection that is already open.
public struct LocalTerminal: Sendable, Hashable {
    /// The name the terminal announces, for example `xterm-ghostty`.
    public let name: String
    /// A terminfo database that holds the description of `name`. Leave it
    /// `nil` to read the database of this Mac.
    public let databasePath: String?

    public init(name: String, databasePath: String? = nil) {
        self.name = name
        self.databasePath = databasePath
    }
}

/// Puts the description of the local terminal on a server.
enum RemoteTerminfo {
    /// The name that every server understands. It is the answer when the
    /// description cannot go across.
    static let compatibleName = "xterm-256color"

    /// How long the far end may take. The command is small, but a slow link
    /// must not hold the first pane back for ever.
    static let limit: TimeInterval = 20

    /// The description of the local terminal, as terminfo source text.
    ///
    /// Returns `nil` when this Mac does not hold the description. Termora then
    /// has nothing to send, and the connection uses the compatible name.
    static func source(of terminal: LocalTerminal) async -> String? {
        var environment = ProcessInfo.processInfo.environment
        if let path = terminal.databasePath { environment["TERMINFO"] = path }

        let result = await ProcessRunner.run(
            "/usr/bin/infocmp", ["-x", terminal.name],
            environment: environment, limit: 10
        )
        guard result.succeeded, !result.output.isEmpty else { return nil }
        return result.output
    }

    /// The command that compiles the description into the home directory of
    /// the far user.
    ///
    /// `tic` reads the source from standard input. The last step asks the far
    /// database for the name again: `tic` calls a warning a success, so the
    /// only proof that the name now works is to look it up. A server without
    /// `tic` ends the line early, and the status says so.
    ///
    /// - Parameter directory: where to put the description on the far host.
    ///   Empty means `$HOME/.terminfo`, which is where `ncurses` looks first.
    ///   The far shell reads it as an argument, so a space in it is safe.
    static func installWords(for name: String, directory: String = "") -> [String] {
        let script = """
        dir="${1:-$HOME/.terminfo}"; \
        mkdir -p "$dir" \
        && tic -x -o "$dir" - >/dev/null 2>&1 \
        && TERMINFO="$dir" infocmp -x \(POSIXQuote.quote(name)) >/dev/null 2>&1
        """
        return ["sh", "-c", script, "termora-terminfo", directory]
    }

    /// A short, stable name for one description.
    ///
    /// The fingerprint goes into the cache, so a new version of the terminal
    /// description reaches a server that already holds the old one.
    static func fingerprint(of source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Remembers which servers already hold which description.
///
/// The work is small, but it is not free: without this, every connection would
/// write to the server again. The record survives a restart, so a server is
/// written to once and then left alone.
@MainActor
final class TerminfoCache {
    private var entries: [String: String] = [:]
    private let fileURL: URL?

    /// - Parameter fileURL: where to keep the record. `nil` keeps it in
    ///   memory only, which is what the tests want.
    init(fileURL: URL? = TerminfoCache.defaultFileURL) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static var defaultFileURL: URL? {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        return caches.appendingPathComponent("Termora/terminfo.json")
    }

    func holds(_ fingerprint: String, for key: String) -> Bool {
        entries[key] == fingerprint
    }

    func record(_ fingerprint: String, for key: String) {
        entries[key] = fingerprint
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    func forget(_ key: String) {
        guard entries.removeValue(forKey: key) != nil else { return }
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
