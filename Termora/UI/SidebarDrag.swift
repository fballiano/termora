//
//  SidebarDrag.swift
//  Termora
//

import Foundation
import SwiftUI
import TermoraModel
import UniformTypeIdentifiers

extension UTType {
    /// The kind Termora puts on the pasteboard while a sidebar row is dragged.
    ///
    /// A kind of its own is used on purpose. With a plain text kind, any text
    /// dragged in from another program would look like a bookmark.
    static let termoraNode = UTType(exportedAs: "com.fabrizioballiano.Termora.node")
}

/// Where the mark is drawn while a drag is over the sidebar.
struct SidebarDropMark: Equatable {
    let rowID: UUID
    let placement: DropPlacement
}

/// Watches a drag over one row and reports where it would land.
///
/// `dropDestination` is not enough here. It says only whether a drag is over
/// the row, so the mark could never follow the pointer up and down inside it.
/// A `DropDelegate` is told the position on every move.
///
/// The dragged node is read from `store.draggingID`, not from the pasteboard.
/// A drag inside one window always knows what it carries, and reading it back
/// from the pasteboard is slow and can fail: the answer arrives on another
/// thread, after the drop has already been reported as done.
struct SidebarDropDelegate: DropDelegate {
    let row: DocumentStore.Row
    let height: CGFloat
    let store: DocumentStore
    @Binding var mark: SidebarDropMark?

    func validateDrop(info _: DropInfo) -> Bool {
        guard let dragged = store.draggingID else { return false }
        return dragged != row.id
    }

    func dropEntered(info: DropInfo) { follow(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        follow(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        if mark?.rowID == row.id { mark = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let placement = self.placement(for: info)
        guard let dragged = store.draggingID else {
            mark = nil
            return false
        }
        // Clear both before the move. The move draws the tree again, and a
        // mark left behind would be drawn with it.
        store.draggingID = nil
        mark = nil
        return store.move(dragged, relativeTo: row.id, placement: placement)
    }

    private func follow(_ info: DropInfo) {
        // A message that arrives after the drag has ended must not put the
        // mark back.
        guard store.draggingID != nil else {
            if mark != nil { mark = nil }
            return
        }
        let next = SidebarDropMark(rowID: row.id, placement: placement(for: info))
        if mark != next { mark = next }
    }

    private func placement(for info: DropInfo) -> DropPlacement {
        DropPlacement.at(
            fraction: height > 0 ? info.location.y / height : 0.5,
            isFolder: row.node.isFolder
        )
    }
}

/// Takes a drop under the last row, which means "back to the top level".
struct TopLevelDropDelegate: DropDelegate {
    let store: DocumentStore
    @Binding var isTargeted: Bool
    @Binding var mark: SidebarDropMark?

    func validateDrop(info _: DropInfo) -> Bool { store.draggingID != nil }

    func dropEntered(info _: DropInfo) {
        isTargeted = true
        mark = nil
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) { isTargeted = false }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        mark = nil
        guard let dragged = store.draggingID else { return false }
        store.draggingID = nil
        return store.moveToTop(dragged)
    }
}

/// Makes the item that travels with a sidebar drag.
///
/// The data on the pasteboard is only a name for the kind. What moves is read
/// from `store.draggingID`, which is set here, as the drag begins.
@MainActor
func sidebarDragProvider(for id: UUID, store: DocumentStore) -> NSItemProvider {
    store.draggingID = id
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.termoraNode.identifier,
        visibility: .ownProcess
    ) { completion in
        completion(Data(id.uuidString.utf8), nil)
        return nil
    }
    return provider
}
