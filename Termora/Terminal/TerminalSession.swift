//
//  TerminalSession.swift
//  Termora
//

import Foundation
import GhosttyTerminal

/// What a pane runs.
struct TerminalLaunch: Equatable, Sendable {
    /// The command line to run. `nil` runs your login shell.
    var command: String?
    /// Extra environment variables for the child process.
    var environment: [String: String]
    var workingDirectory: String?
    /// Keep the pane open after the command exits, so you can read any error.
    var waitAfterCommand: Bool
    /// The name shown on the tab before the program sets a title.
    var title: String

    init(
        command: String? = nil,
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        waitAfterCommand: Bool = true,
        title: String = "Shell"
    ) {
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.waitAfterCommand = waitAfterCommand
        self.title = title
    }

    /// A local login shell. Used for the local terminal and for smoke tests.
    static var loginShell: TerminalLaunch {
        TerminalLaunch(waitAfterCommand: false, title: "Shell")
    }
}

/// One terminal pane.
///
/// This type is the only boundary between Termora and libghostty. Keep every
/// Ghostty call inside it, so that a change of terminal engine stays local.
@MainActor
final class TerminalSession: Identifiable, ObservableObject {
    let id: UUID
    let launch: TerminalLaunch
    let state: TerminalViewState

    /// The child process has exited.
    @Published private(set) var isFinished = false

    /// The owner sets this to remove the pane. The flag reports whether the
    /// child process was still running, so the owner can ask for confirmation.
    var onRequestClose: ((TerminalSession, _ processAlive: Bool) -> Void)?

    init(id: UUID = UUID(), launch: TerminalLaunch) {
        self.id = id
        self.launch = launch
        state = TerminalViewState(controller: GhosttyEnvironment.controller)
        state.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: launch.workingDirectory,
            envVars: launch.environment,
            command: launch.command,
            waitAfterCommand: launch.waitAfterCommand,
            context: .window
        )
        state.onClose = { [weak self] processAlive in
            MainActor.assumeIsolated {
                self?.handleClose(processAlive: processAlive)
            }
        }
    }

    /// The title to show on a tab. The program's own title wins when it sets one.
    var title: String {
        state.title.isEmpty ? launch.title : state.title
    }

    /// Stop drawing a pane that is hidden behind another tab. The grid, the
    /// scrollback, and the child process all stay alive.
    func setVisible(_ isVisible: Bool) {
        state.isSurfaceVisible = isVisible
    }

    func focus() {
        state.requestFocus()
    }

    /// Type text into the pane, as if you had typed it.
    @discardableResult
    func send(_ text: String) -> Bool {
        state.send(text)
    }

    private func handleClose(processAlive: Bool) {
        isFinished = !processAlive
        onRequestClose?(self, processAlive)
    }
}
