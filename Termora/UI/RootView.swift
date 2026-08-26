//
//  RootView.swift
//  Termora
//

import SwiftUI

/// Chooses the screen for the current state of the document.
struct RootView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var sessions: SessionsController
    @EnvironmentObject private var importer: ImportController

    var body: some View {
        Group {
            switch store.phase {
            case .welcome:
                WelcomeView()
            case let .locked(url):
                UnlockView(url: url)
            case .unlocked:
                MainWindowView()
            }
        }
        .alert(
            "Termora",
            isPresented: Binding(
                get: { store.errorMessage != nil || sessions.errorMessage != nil },
                set: { showing in
                    if !showing {
                        store.errorMessage = nil
                        sessions.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
                sessions.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? sessions.errorMessage ?? "")
        }
        // OpenSSH is waiting for this answer, so the sheet always answers,
        // even when it is dismissed.
        .sheet(item: $sessions.pendingPrompt) { request in
            PromptSheet(request: request) { sessions.pendingPrompt = nil }
        }
        .sheet(isPresented: $importer.isPresented) {
            ImportSheet(controller: importer)
        }
        // The welcome and unlock screens live in a small fixed window, the
        // way a password manager greets you. The window grows back when the
        // document opens.
        .background(WindowShape(isCompact: store.phase != .unlocked))
    }
}

/// Sizes the window to the phase: compact while locked, large while open.
private struct WindowShape: NSViewRepresentable {
    let isCompact: Bool

    static let compactSize = NSSize(width: 560, height: 600)
    static let openSize = NSSize(width: 1250, height: 780)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.apply(isCompact, to: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.apply(isCompact, to: view) }
    }

    @MainActor
    final class Coordinator {
        /// The shape that is already applied, so a repeat changes nothing.
        private var applied: Bool?

        func apply(_ isCompact: Bool, to view: NSView) {
            guard let window = view.window, applied != isCompact else { return }
            applied = isCompact
            if isCompact {
                WindowMemory.isArmed = false
                window.styleMask.remove(.resizable)
                window.setContentSize(WindowShape.compactSize)
                window.center()
                return
            }

            window.styleMask.insert(.resizable)
            // Back to where the person left the window, not to a fixed
            // size. `WindowMemory` skips the compact shape, so the saved
            // frame is always an open one.
            if let frame = WindowMemory.savedFrame {
                window.setFrame(frame, display: true)
            } else {
                window.setContentSize(WindowShape.openSize)
                window.center()
            }
            if WindowMemory.wasFullScreen,
               !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            // From here on, moves and resizes are the person's own.
            WindowMemory.isArmed = true
        }
    }
}

/// The bookmark tree, the terminal tabs, and the inspector.
struct MainWindowView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var sessions: SessionsController
    /// The document always opens with the tree in sight. Without this
    /// binding, the split view restores a collapsed sidebar from a past
    /// launch, and the window opens showing nothing to connect to.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            TerminalTabsView()
        }
        // The name of the document is shown at the foot of the sidebar. A
        // large title over the terminal takes room and says nothing new.
        .navigationTitle("")
        // The tabs are drawn inside the window's title bar, so they take no
        // row of their own. See `TitlebarTabs`.
        .background(
            TitlebarTabs(sessions: sessions, store: store).frame(width: 0, height: 0)
        )
        // The editor is a sheet, so the terminal keeps the whole window.
        .sheet(item: Binding(
            get: { store.editingID.map(EditTarget.init) },
            set: { if $0 == nil { store.editingID = nil } }
        )) { _ in
            EditSheet()
        }
    }
}




/// Wraps the identifier being edited, so a sheet can be driven by it.
struct EditTarget: Identifiable {
    let id: UUID
}

/// The editor, shown over the window rather than beside it.
struct EditSheet: View {
    @EnvironmentObject private var store: DocumentStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.headline)
                Spacer()
                // There is no Cancel on purpose, so the model is said here.
                Text("Changes apply immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { store.editingID = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()
            InspectorView()
        }
        // The sheet can grow: with a few tunnels and notes, 620 points is a
        // keyhole on a big screen.
        .frame(minWidth: 620, idealWidth: 660, maxWidth: 880,
               minHeight: 560, idealHeight: 660, maxHeight: 920)
    }

    private var title: String {
        if let connection = store.selectedConnection { return connection.name }
        if let folder = store.selectedFolder { return folder.name }
        return "Edit"
    }
}
