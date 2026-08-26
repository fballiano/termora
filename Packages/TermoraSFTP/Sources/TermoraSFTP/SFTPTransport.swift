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

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

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
        process.terminationHandler = { _ in onClose() }

        try process.run()
    }

    public func send(_ data: Data) throws {
        guard process.isRunning else { throw SFTPError.channelClosed }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
