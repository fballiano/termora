//
//  SFTPTransport.swift
//  TermoraSFTP
//

import Foundation

/// Carries bytes to and from an SFTP server.
///
/// The real transport is the pipe pair of `ssh … -s sftp`. The tests use a
/// transport that talks to a server in the same process, so the protocol can
/// be checked without a network.
public protocol SFTPTransport: AnyObject, Sendable {
    func send(_ data: Data) throws
    /// Starts delivering bytes. Called once, before anything is sent.
    func start(onData: @escaping @Sendable (Data) -> Void,
               onClose: @escaping @Sendable () -> Void) throws
    func stop()
}

/// Runs `ssh … -s sftp` and carries the protocol on its pipes.
///
/// The command comes from `SSHConnection.sftpArguments()`, so the channel
/// travels on the connection that is already open and nothing authenticates
/// a second time.
public final class SFTPProcessTransport: SFTPTransport, @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorPipe = Pipe()
    /// What ssh wrote to standard error. It says why a channel failed, and
    /// draining the pipe keeps a chatty ssh from blocking on a full buffer.
    private let errorBuffer = BoundedTextBuffer()

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The last of what ssh wrote to standard error, for an error message.
    public var errorOutput: String { errorBuffer.text }

    public func start(onData: @escaping @Sendable (Data) -> Void,
                      onClose: @escaping @Sendable () -> Void) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                onClose()
            } else {
                onData(data)
            }
        }
        let errors = errorBuffer
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errors.append(String(decoding: data, as: UTF8.self))
            }
        }
        process.terminationHandler = { _ in onClose() }

        try process.run()
    }

    public func send(_ data: Data) throws {
        guard process.isRunning else { throw SFTPError.channelClosed }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// Text that several threads may append to. Only the newest part is kept,
/// so a talkative `ssh -v` cannot grow it without limit.
private final class BoundedTextBuffer: @unchecked Sendable {
    private static let capacity = 16 * 1024
    private let lock = NSLock()
    private var storage = ""

    var text: String { lock.withLock { storage } }

    func append(_ piece: String) {
        lock.withLock {
            storage += piece
            if storage.count > Self.capacity {
                storage = String(storage.suffix(Self.capacity))
            }
        }
    }
}
