//
//  SSHConnection.swift
//  TermoraSSH
//

import Foundation
import TermoraModel

/// One live connection: a control master process and everything on it.
///
/// The master is separate from any terminal pane, so you can close every pane
/// and keep the connection and its tunnels alive.
@MainActor
public final class SSHConnection: ObservableObject, Identifiable {
    public enum State: Equatable, Sendable {
        case idle
        /// The master is running and OpenSSH is still authenticating.
        case connecting
        case connected
        /// The master stopped. The text is the last useful line of its output.
        case failed(String)
        case disconnected
    }

    public let id: UUID
    public let name: String
    public let target: SSHTarget
    /// The random token that ties an askpass question to this connection.
    public let sessionToken: String
    public let controlPath: String

    @Published public private(set) var state: State = .idle
    @Published public private(set) var activeForwards: Set<UUID> = []
    /// Everything the master wrote to standard error, for the details sheet.
    @Published public private(set) var log: String = ""

    private var master: Process?
    private let environment: [String: String]
    /// Collects standard error as it arrives, without hopping between threads.
    ///
    /// The exit handler must see everything OpenSSH wrote, so the buffer is
    /// filled synchronously on the reading thread. Sending each piece to the
    /// main actor instead would let the process exit before the last and most
    /// important line arrives, and a real failure would then look like a
    /// normal close.
    private let logBuffer = LogBuffer()
    /// Set before Termora closes the connection itself, so that a normal exit
    /// is never reported as a failure.
    private var isClosingOnPurpose = false

    /// How long to wait for authentication before giving up. A person may be
    /// typing a password or touching a security key.
    private let readyTimeout: Duration
    private static let pollInterval: Duration = .milliseconds(200)

    init(id: UUID, name: String, target: SSHTarget, sessionToken: String,
         controlPath: String, environment: [String: String],
         readyTimeout: Duration = .seconds(180)) {
        self.id = id
        self.name = name
        self.target = target
        self.sessionToken = sessionToken
        self.controlPath = controlPath
        self.environment = environment
        self.readyTimeout = readyTimeout
    }

    public var isConnected: Bool { state == .connected }

    // MARK: - Connecting

    public func connect() async {
        guard state != .connected, state != .connecting else { return }
        state = .connecting
        log = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommand.executable)
        process.arguments = SSHCommand.master(target: target, controlPath: controlPath)
        process.environment = environment

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        let buffer = logBuffer
        buffer.reset()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer.append(String(decoding: data, as: UTF8.self))
        }

        process.terminationHandler = { [weak self] finished in
            // Take whatever is still in the pipe before deciding what the exit
            // means. The process has gone, so this returns at once.
            let handle = errorPipe.fileHandleForReading
            handle.readabilityHandler = nil
            let remaining = handle.availableData
            if !remaining.isEmpty {
                buffer.append(String(decoding: remaining, as: UTF8.self))
            }
            let text = buffer.text
            let status = finished.terminationStatus
            Task { @MainActor in self?.masterDidExit(status: status, output: text) }
        }

        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        master = process

        await waitUntilReady()
    }

    /// Waits until `ssh -O check` succeeds, the master exits, or time runs out.
    private func waitUntilReady() async {
        let deadline = ContinuousClock.now + readyTimeout
        while ContinuousClock.now < deadline {
            if case .failed = state { return }
            if state == .disconnected { return }

            if await runControlCommand(SSHCommand.check(target: target, controlPath: controlPath)).succeeded {
                if state == .connecting { state = .connected }
                return
            }
            guard master?.isRunning == true else { return }
            try? await Task.sleep(for: Self.pollInterval)
        }
        state = .failed("The connection did not open in time.")
        await disconnect()
    }

    private func masterDidExit(status: Int32, output: String) {
        master = nil
        log = output

        switch state {
        case .connected, .connecting:
            break
        default:
            return
        }

        if isClosingOnPurpose {
            state = .disconnected
            return
        }

        // A quiet exit is a normal end, whatever the status code: `ssh -O exit`
        // and a terminated master both leave a non-zero status behind, and
        // OpenSSH writes progress notes even when nothing went wrong.
        let result = CommandResult(status: status, output: "", errorOutput: output)
        state = result.isQuiet ? .disconnected : .failed(result.summary)
    }

    // MARK: - Using the connection

    /// The command line for a terminal pane. It attaches to the master, so it
    /// opens with no second authentication.
    public func terminalCommandLine() -> String {
        POSIXQuote.line(
            [SSHCommand.executable] + SSHCommand.session(target: target, controlPath: controlPath)
        )
    }

    /// The arguments for an SFTP channel on this same connection.
    public func sftpArguments() -> [String] {
        SSHCommand.sftpSubsystem(target: target, controlPath: controlPath)
    }

    /// The argv that runs one command on this connection and then returns.
    /// The `termora` tool executes it, so the far output streams natively
    /// and the far exit code becomes the tool's own.
    ///
    /// The words are quoted into one line for the far shell. OpenSSH would
    /// otherwise join them with plain spaces, and the far shell would split
    /// a word such as `a b` back into two.
    public func commandArguments(_ words: [String]) -> [String] {
        [SSHCommand.executable]
            + SSHCommand.session(target: target, controlPath: controlPath)
            + [POSIXQuote.line(words)]
    }

    @discardableResult
    public func addForward(_ forward: PortForward) async -> CommandResult {
        let result = await runControlCommand(
            SSHCommand.addForward(forward, target: target, controlPath: controlPath)
        )
        if result.succeeded { activeForwards.insert(forward.id) }
        return result
    }

    @discardableResult
    public func cancelForward(_ forward: PortForward) async -> CommandResult {
        let result = await runControlCommand(
            SSHCommand.cancelForward(forward, target: target, controlPath: controlPath)
        )
        if result.succeeded { activeForwards.remove(forward.id) }
        return result
    }

    public func disconnect() async {
        isClosingOnPurpose = true
        _ = await runControlCommand(SSHCommand.exit(target: target, controlPath: controlPath))
        if let master, master.isRunning { master.terminate() }
        master = nil
        activeForwards.removeAll()
        if case .failed = state {} else { state = .disconnected }
    }

    private func runControlCommand(_ arguments: [String]) async -> CommandResult {
        await ProcessRunner.run(SSHCommand.executable, arguments, environment: environment)
    }
}

/// A string that several threads may append to.
private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var text: String { lock.withLock { storage } }

    func append(_ piece: String) {
        lock.withLock { storage += piece }
    }

    func reset() {
        lock.withLock { storage = "" }
    }
}
