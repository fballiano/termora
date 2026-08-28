//
//  TermoraApp.swift
//  Termora
//

import AppKit
import SwiftUI

/// The main window's last frame and full-screen state, across launches.
///
/// SwiftUI's own frame autosave writes a key but never reads it back on
/// this macOS, and the unlock flow reshapes the window anyway: `WindowShape`
/// sets a fixed size when the document opens. So the memory is explicit.
/// The delegate writes it on every move and resize, and `WindowShape` reads
/// it when the window grows back after unlock.
@MainActor
enum WindowMemory {
    private static let frameKey = "TermoraMainWindowFrame"
    private static let wasFullScreenKey = "TermoraMainWindowWasFullScreen"

    static var wasFullScreen: Bool {
        get { UserDefaults.standard.bool(forKey: wasFullScreenKey) }
        set { UserDefaults.standard.set(newValue, forKey: wasFullScreenKey) }
    }

    /// The saved frame, when there is one that still makes sense.
    static var savedFrame: NSRect? {
        guard let saved = UserDefaults.standard.string(forKey: frameKey) else {
            return nil
        }
        let frame = NSRectFromString(saved)
        return frame.isEmpty ? nil : frame
    }

    /// Armed by `WindowShape` once the open shape is applied. The window
    /// exists briefly at `defaultSize` before the first shaping pass, and
    /// a resize seen then must not overwrite the saved frame.
    static var isArmed = false

    /// Writes the window's frame, when it is one worth remembering.
    ///
    /// The compact unlock window is not resizable, so the check on
    /// `.resizable` keeps its shape out of the memory. A full-screen frame
    /// is not a size the person chose, so it is skipped too; the flag
    /// remembers that state instead.
    static func remember(_ window: NSWindow?) {
        guard isArmed else { return }
        guard let window,
              window.collectionBehavior.contains(.fullScreenPrimary),
              window.styleMask.contains(.resizable),
              !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameKey)
    }
}

/// Answers ⌘Q. With open sessions the person is asked first, and the
/// connections close before the application goes.
///
/// It also holds ⌘⌥← and ⌘⌥→ for the tab walk. A menu item carries one
/// key equivalent, and Next Tab already shows ⌘⇧], so the arrows come
/// from an event monitor instead of a second, repeated menu item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the application when the scene appears.
    var sessions: SessionsController?

    /// The monitor lives as long as the application.
    private var tabKeyMonitor: Any?

    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124

    private var windowObservers: [NSObjectProtocol] = []
    /// Leaving full screen as part of quitting must not clear the flag,
    /// or the next launch opens windowed.
    private var isTerminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the first window exists, so no change is missed.
        observeWindowState()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // An arrow key also raises `.function` and `.numericPad`, so the
            // comparison drops them before it looks for ⌘⌥ alone.
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad])
            guard flags == [.command, .option] else { return event }

            let step: Int
            switch event.keyCode {
            case Self.leftArrowKeyCode: step = -1
            case Self.rightArrowKeyCode: step = 1
            default: return event
            }

            // The monitor runs on the main thread, but its closure carries no
            // isolation, so the fact is asserted rather than assumed silently.
            MainActor.assumeIsolated { self?.sessions?.selectRelativeTab(step) }
            return nil
        }
    }

    /// The observers watch every window, because the SwiftUI window is not
    /// reachable from here directly. `WindowMemory.remember` tells the
    /// main open window apart from the unlock shape and from Settings.
    private func observeWindowState() {
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            windowObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { note in
                // The queue is the main queue, so the window is on its
                // actor; the notification itself is not Sendable and
                // stays outside.
                nonisolated(unsafe) let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    WindowMemory.remember(window)
                }
            })
        }
        windowObservers.append(center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main
        ) { note in
            nonisolated(unsafe) let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window,
                      window.collectionBehavior.contains(.fullScreenPrimary) else { return }
                WindowMemory.wasFullScreen = true
            }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main
        ) { [weak self] note in
            nonisolated(unsafe) let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, !self.isTerminating, let window,
                      window.collectionBehavior.contains(.fullScreenPrimary) else { return }
                WindowMemory.wasFullScreen = false
            }
        })
    }

    func applicationShouldTerminate(_ sender: NSApplication)
        -> NSApplication.TerminateReply {
        isTerminating = true
        guard let sessions, !sessions.tabs.isEmpty else { return .terminateNow }

        if AppSettings.confirmQuit {
            let count = sessions.tabs.count
            let alert = NSAlert()
            alert.messageText = count == 1
                ? "Quit with one open session?"
                : "Quit with \(count) open sessions?"
            alert.informativeText = "Every connection closes, with its tunnels."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                isTerminating = false
                return .terminateCancel
            }
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
    @StateObject private var autoLock: AutoLockController
    @StateObject private var agentGateway: AgentGateway

    init() {
        // Before anything reads a setting, so every reader sees one default.
        AppSettings.registerDefaults()
        let store = MainActor.assumeIsolated { DocumentStore() }
        _store = StateObject(wrappedValue: store)
        let sessions = MainActor.assumeIsolated { SessionsController(store: store) }
        _sessions = StateObject(wrappedValue: sessions)
        _importer = StateObject(wrappedValue: MainActor.assumeIsolated {
            ImportController(store: store)
        })
        _autoLock = StateObject(wrappedValue: MainActor.assumeIsolated {
            AutoLockController(store: store, sessions: sessions)
        })
        _agentGateway = StateObject(wrappedValue: MainActor.assumeIsolated {
            AgentGateway(store: store, sessions: sessions)
        })
    }

    var body: some Scene {
        WindowGroup("Termora") {
            RootView()
                .environmentObject(store)
                .environmentObject(sessions)
                .environmentObject(importer)
                .environmentObject(sessions.remoteEdits)
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

            }

            // ⌘W must reach one item only. The system's own File, Close also
            // answers ⌘W, the File menu is searched first, and the window
            // then closes with every terminal in it. This group replaces the
            // system items, so ⌘W closes a tab and ⇧⌘W closes the window,
            // the way Terminal and Safari divide them.
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { sessions.closeSelectedTab() }
                    .keyboardShortcut("w", modifiers: [.command])
                    .disabled(sessions.selectedTab == nil)
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
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

        // Termora, Settings… (⌘,).
        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
