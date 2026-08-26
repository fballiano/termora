//
//  SFTPPromise.swift
//  TermoraSFTP
//

import Foundation
import UniformTypeIdentifiers

/// Describes one dragged row to the file promise machinery.
///
/// Dragging several rows to Finder means handing over one promise for each
/// row. This type holds the decisions that promise needs, kept apart from
/// AppKit so they can be checked on their own.
///
/// A promise carries no data. Finder asks for the file only when the drag is
/// let go, so dragging a large folder about costs nothing until you mean it.
public enum SFTPPromise {
    public struct Descriptor: Hashable, Sendable {
        /// The type Finder is told to expect. A folder must be announced as a
        /// folder, or Finder copies it as a single file.
        public let typeIdentifier: String
        public let fileName: String
        /// What travels with the promise. The callbacks that Finder makes do
        /// not run on the main actor, so they cannot reach the browser: the
        /// name and the path go with the promise instead.
        public let userInfo: [String: String]
    }

    static let nameKey = "name"
    static let pathKey = "path"

    /// The promise for one entry, or `nil` when the entry cannot be dragged.
    ///
    /// A symbolic link is not offered, for the same reason a copy does not
    /// follow one: a link that points at its own parent has no end.
    public static func descriptor(for entry: SFTPEntry) -> Descriptor? {
        guard !entry.isSymbolicLink else { return nil }

        let type: UTType
        if entry.isDirectory {
            type = .folder
        } else {
            let suffix = (entry.name as NSString).pathExtension
            type = UTType(filenameExtension: suffix) ?? .data
        }

        return Descriptor(
            typeIdentifier: type.identifier,
            fileName: entry.name,
            userInfo: [nameKey: entry.name, pathKey: entry.path]
        )
    }

    /// One promise for each row, with the rows that cannot be dragged left out.
    public static func descriptors(for entries: [SFTPEntry]) -> [Descriptor] {
        entries.compactMap(descriptor(for:))
    }

    public static func fileName(from userInfo: Any?) -> String? {
        (userInfo as? [String: String])?[nameKey]
    }

    public static func path(from userInfo: Any?) -> String? {
        (userInfo as? [String: String])?[pathKey]
    }
}
