//
//  TermoraApp.swift
//  Termora
//

import AppKit
import SwiftUI

/// Answers ⌘Q. With open sessions the person is asked first, and the
/// connections close before the application goes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the application when the scene appears.
    var sessions: SessionsController?

    func applicationShouldTerminate(_ sender: NSApplication)
        -> NSApplication.TerminateReply {
        guard let sessions, !sessions.tabs.isEmpty else { return .terminateNow }

        let count = sessions.tabs.count
        let alert = NSAlert()
        alert.messageText = count == 1
            ? "Quit with one open session?"
            : "Quit with \(count) open sessions?"
        alert.informativeText = "Every connection closes, with its tunnels."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        // The control masters get an orderly `-O exit`, so no ssh process
        // is left behind. The application waits for that, then goes.
        Task {
            await sessions.disconnectEverything()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct TermoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: DocumentStore
    @StateObject private var sessions: SessionsController
    @StateObject private var importer: ImportController

    init() {
        let store = MainActor.assumeIsolated { DocumentStore() }
        _store = StateObject(wrappedValue: store)
        _sessions = StateObject(wrappedValue: MainActor.assumeIsolated {
            SessionsController(store: store)
        })
        _importer = StateObject(wrappedValue: MainActor.assumeIsolated {
            ImportController(store: store)
        })
    }

    var body: some Scene {
        WindowGroup("Termora") {
            RootView()
                .environmentObject(store)
                .environmentObject(sessions)
                .environmentObject(importer)
                .onAppear { appDelegate.sessions = sessions }
        }
        .defaultSize(width: 1250, height: 780)
        .commands {
            // View, Toggle Sidebar (⌃⌘S). The window toolbar is hidden, so
            // the menu is the way to fold the sidebar away and back.
            SidebarCommands()

            // ⌘N makes a bookmark, not a window. One window is the design.
            CommandGroup(replacing: .newItem) {
                Button("New Connection") { store.addConnection() }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(!store.isUnlocked)
                Button("New Folder") { store.addFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!store.isUnlocked)
                Divider()
                Menu("Open Recent") {
                    ForEach(store.recentDocumentURLs, id: \.path) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            store.openRecent(at: url)
                        }
                    }
                }
                .disabled(store.recentDocumentURLs.isEmpty)
            }

            CommandMenu("Session") {
                Button("Connect") {
                    if let connection = store.selectedConnection {
                        sessions.open(connection: connection)
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(store.selectedConnection == nil)

                Button("Browse Files") {
                    if let connection = store.selectedConnection {
                        sessions.openFiles(connection: connection)
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.selectedConnection == nil)

                Divider()

                Button("Split Right") { sessions.splitFocusedPane(axis: .horizontal) }
                    .keyboardShortcut("d", modifiers: [.command])
                Button("Split Down") { sessions.splitFocusedPane(axis: .vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                // The names in this menu follow the open tabs, so ⌘1…⌘9
                // reads as "go to that tab", not as a riddle.
                Menu("Go to Tab") {
                    ForEach(Array(sessions.tabs.prefix(9).enumerated()), id: \.element.id) { at, tab in
                        Button(tab.connectionName) { sessions.selectTab(at: at) }
                            .keyboardShortcut(
                                KeyEquivalent(Character("\(at + 1)")),
                                modifiers: [.command]
                            )
                    }
                }
                .disabled(sessions.tabs.isEmpty)

                Button("Next Tab") { sessions.selectRelativeTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(sessions.tabs.count < 2)
                Button("Previous Tab") { sessions.selectRelativeTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(sessions.tabs.count < 2)

                Divider()

                Button("Close Tab") { sessions.closeSelectedTab() }
                    .keyboardShortcut("w", modifiers: [.command])
                    .disabled(sessions.selectedTab == nil)
            }

            CommandGroup(after: .newItem) {
                Button("Import from Royal TSX…") { importer.begin() }
                    .disabled(!store.isUnlocked)
                Divider()
                Button("Lock Document") { store.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(!store.isUnlocked)
            }
        }
    }
}
