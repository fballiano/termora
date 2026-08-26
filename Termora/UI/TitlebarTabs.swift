//
//  TitlebarTabs.swift
//  Termora
//

import AppKit
import SwiftUI

/// Puts the row of tabs inside the window's own title bar.
///
/// The row was moved into the detail column once, under a transparent
/// title bar. macOS 26 then stretched a scroll-edge backdrop from the file
/// browser's tables up to the window top, over the row, and no public API
/// turns that off for an AppKit scroll view. A title-bar accessory is the
/// one place that is composed above that backdrop, so the row lives here.
///
/// The first version of this accessory had one defect: it started at a fixed
/// x, and the floating sidebar drew over the first tab. The row now takes a
/// live leading inset from the real sidebar width, so no tab can sit under
/// the sidebar panel.
struct TitlebarTabs: NSViewRepresentable {
    let sessions: SessionsController
    let store: DocumentStore

    /// The room the window's edge needs on the right.
    private static let roomOnTheRight: CGFloat = 8

    func makeCoordinator() -> Coordinator {
        Coordinator(sessions: sessions, store: store)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not known until the view joins it.
        DispatchQueue.main.async { context.coordinator.install(from: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.install(from: view) }
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// The live leading inset of the row: how far the sidebar reaches into it.
    @MainActor
    final class RowInset: ObservableObject {
        @Published var leading: CGFloat = 0
    }

    @MainActor
    final class Coordinator: NSObject {
        private let sessions: SessionsController
        private let store: DocumentStore
        private let inset = RowInset()
        private var accessory: NSTitlebarAccessoryViewController?
        private weak var window: NSWindow?
        private var observers: [any NSObjectProtocol] = []

        init(sessions: SessionsController, store: DocumentStore) {
            self.sessions = sessions
            self.store = store
        }

        func install(from view: NSView) {
            guard accessory == nil, let window = view.window else { return }
            self.window = window

            let content = TitlebarRow(inset: inset)
                .environmentObject(sessions)
                .environmentObject(store)
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(x: 0, y: 0, width: 400, height: TabBar.height)

            let controller = NSTitlebarAccessoryViewController()
            controller.view = hosting
            // `.leading` sits in the title bar itself, after the round window
            // buttons. `.bottom` would add a second row.
            controller.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(controller)
            accessory = controller

            layout()
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            })
            // The sidebar reports every width change through its split view,
            // including a collapse and its return. The observer takes every
            // split view in the application: the layout pass is cheap, and
            // it reads only this window.
            observers.append(center.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            })
        }

        /// Sizes the row to the window and moves its content clear of the
        /// sidebar.
        private func layout() {
            guard let window, let view = accessory?.view else { return }

            // Where the row starts, from the left edge of the window. The
            // frame's own x is relative to the title bar container, which
            // does not start at the window edge.
            let rowStart = view.convert(NSPoint.zero, to: nil).x

            // The title bar is taller than the row: the sidebar header
            // stretches it. The accessory takes the whole height, and the
            // row centres inside it, level with the round window buttons.
            let titlebarHeight = window.frame.height - window.contentLayoutRect.height

            let available = window.frame.width
                - rowStart
                - TitlebarTabs.roomOnTheRight
            let size = NSSize(
                width: max(120, available),
                height: max(TabBar.height, titlebarHeight)
            )
            if view.frame.size != size { view.frame.size = size }

            // Where the sidebar ends, in the row's own coordinates, so the
            // tabs never sit under the sidebar panel.
            let sidebarEnd = sidebarWidth(in: window)
            inset.leading = max(0, sidebarEnd - rowStart + 10)
        }

        /// The width of the sidebar column, or zero while it is collapsed.
        private func sidebarWidth(in window: NSWindow) -> CGFloat {
            guard let contentView = window.contentView,
                  let splitView = Self.findSplitView(in: contentView),
                  let sidebar = splitView.arrangedSubviews.first
            else { return 0 }
            return sidebar.isHidden ? 0 : sidebar.frame.width
        }

        private static func findSplitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for child in view.subviews {
                if let found = findSplitView(in: child) { return found }
            }
            return nil
        }

        func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            if let accessory, let window,
               let at = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: at)
            }
            accessory = nil
        }
    }
}

/// What the title bar holds: the tabs, the tab list, and the lock.
private struct TitlebarRow: View {
    @EnvironmentObject private var sessions: SessionsController
    @EnvironmentObject private var store: DocumentStore
    @ObservedObject var inset: TitlebarTabs.RowInset

    var body: some View {
        HStack(spacing: 8) {
            TabBar()
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            // Tabs past the edge scroll out of sight with no mark, so this
            // list always reaches every tab.
            if sessions.tabs.count > 1 {
                Menu {
                    ForEach(sessions.tabs) { tab in
                        Button {
                            sessions.selectedTabID = tab.id
                        } label: {
                            Label(tab.connectionName, systemImage: tab.iconName)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("All tabs")
            }

            Button { store.lock() } label: {
                Image(systemName: "lock")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Lock the document")
        }
        // The leading room keeps the row clear of the sidebar panel; the
        // trailing room keeps the lock clear of the window's rounded corner.
        .padding(.leading, inset.leading)
        .padding(.trailing, 18)
        // The hosting view is as tall as the title bar. The row floats in
        // its vertical centre instead of hugging the top edge.
        .frame(maxHeight: .infinity, alignment: .center)
    }
}
