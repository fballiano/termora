//
//  DropPlacement.swift
//  TermoraModel
//

import Foundation

/// Where a dragged node lands in relation to the row it is dropped on.
public enum DropPlacement: Hashable, Sendable {
    /// Above the row, as a brother of it.
    case before
    /// Below the row, as a brother of it.
    case after
    /// Inside the row, which must be a folder.
    case inside

    /// Reads the placement from where the pointer sits in a row.
    ///
    /// - Parameters:
    ///   - fraction: 0 at the top of the row, 1 at the bottom.
    ///   - isFolder: a folder can also be dropped into, so it keeps a band in
    ///     the middle for that. A bookmark has no inside, so its row splits in
    ///     two.
    public static func at(fraction: Double, isFolder: Bool) -> DropPlacement {
        let position = min(max(fraction, 0), 1)
        guard isFolder else { return position < 0.5 ? .before : .after }
        if position < 0.25 { return .before }
        if position > 0.75 { return .after }
        return .inside
    }
}
