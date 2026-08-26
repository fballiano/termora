//
//  PaneTree.swift
//  Termora
//

import Foundation
import SwiftUI

/// One node of the split tree inside a tab.
///
/// A node is either a pane or a division into two nodes. Splitting a pane
/// turns its node into a division and moves the old pane into the first child,
/// so the pane object, and therefore the running process, is never disturbed.
@MainActor
final class PaneNode: Identifiable, ObservableObject {
    enum Content {
        case pane(TerminalSession)
        case split(axis: Axis, first: PaneNode, second: PaneNode)
    }

    let id = UUID()
    @Published var content: Content
    /// The share of the space given to the first child, between 0.1 and 0.9.
    @Published var ratio: Double = 0.5

    init(_ session: TerminalSession) {
        content = .pane(session)
    }

    init(axis: Axis, first: PaneNode, second: PaneNode) {
        content = .split(axis: axis, first: first, second: second)
    }

    /// Every pane below this node, in the order they are drawn.
    var panes: [TerminalSession] {
        switch content {
        case let .pane(session): [session]
        case let .split(_, first, second): first.panes + second.panes
        }
    }

    /// Turns the pane with this identifier into a division.
    /// Returns false when the pane is not below this node.
    @discardableResult
    func split(paneID: UUID, axis: Axis, with session: TerminalSession) -> Bool {
        switch content {
        case let .pane(existing):
            guard existing.id == paneID else { return false }
            content = .split(axis: axis, first: PaneNode(existing), second: PaneNode(session))
            ratio = 0.5
            return true
        case let .split(_, first, second):
            return first.split(paneID: paneID, axis: axis, with: session)
                || second.split(paneID: paneID, axis: axis, with: session)
        }
    }

    /// Removes a pane. The node that held it takes the place of its sibling.
    /// Returns false when this node itself is the pane, because a node cannot
    /// remove itself; the tab handles that case.
    @discardableResult
    func remove(paneID: UUID) -> Bool {
        guard case let .split(_, first, second) = content else { return false }

        if case let .pane(session) = first.content, session.id == paneID {
            adopt(second)
            return true
        }
        if case let .pane(session) = second.content, session.id == paneID {
            adopt(first)
            return true
        }
        return first.remove(paneID: paneID) || second.remove(paneID: paneID)
    }

    /// Takes the shape of another node, so the surviving side fills the space.
    private func adopt(_ other: PaneNode) {
        content = other.content
        ratio = other.ratio
    }

    /// True when this node is a single pane with that identifier.
    func isPane(_ paneID: UUID) -> Bool {
        if case let .pane(session) = content { return session.id == paneID }
        return false
    }
}
