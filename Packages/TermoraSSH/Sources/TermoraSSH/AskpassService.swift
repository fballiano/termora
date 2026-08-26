//
//  AskpassService.swift
//  TermoraSSH
//

import Darwin
import Foundation

/// Answers the questions that `termora-askpass` forwards.
///
/// The service listens on a Unix socket inside the per-user temporary
/// directory, which macOS creates with mode 0700. The socket file itself is
/// 0600. Only processes running as you can reach it, which is the same
/// protection that `ssh-agent` relies on.
///
/// The service does not know any secret. It hands each request to the
/// responder, which checks the session token and returns the answer.
public final class AskpassService: @unchecked Sendable {
    /// Returns the answer, or `nil` to cancel the prompt.
    public typealias Responder = @Sendable (AskpassRequest) async -> String?

    public let socketURL: URL

    private let responderLock = NSLock()
    private var storedResponder: Responder?
    private let queue = DispatchQueue(label: "com.fabrizioballiano.Termora.askpass")
    private var listenDescriptor: Int32 = -1
    private var source: DispatchSourceRead?

    /// The longest answer the service will accept from a request line.
    private static let maximumRequestBytes = 64 * 1024

    /// Set this before `start()`. It is held behind a lock, because a request
    /// arrives on the socket queue.
    public var responder: Responder? {
        get { responderLock.withLock { storedResponder } }
        set { responderLock.withLock { storedResponder = newValue } }
    }

    /// The private directory that holds the socket. Removed on `stop()`.
    private let socketDirectory: URL

    public init() throws {
        // The socket lives alone in a directory that only this account may
        // enter. That protects it without touching `umask`, which is global to
        // the process: changing it would also strip permissions from every
        // file and directory that another thread creates meanwhile.
        socketDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: socketDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // A short name, because a Unix socket path may not exceed 104 bytes.
        socketURL = socketDirectory.appendingPathComponent("s.sock")
        guard socketURL.path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw AskpassServiceError.socketPathTooLong(socketURL.path)
        }
    }

    deinit { stop() }

    // MARK: - Lifetime

    public func start() throws {
        try queue.sync {
            guard listenDescriptor < 0 else { return }

            unlink(socketURL.path)
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw AskpassServiceError.cannotCreateSocket(errno) }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let pathBytes = Array(socketURL.path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            // The directory above already keeps everyone else out. This makes
            // the socket itself private as well.
            chmod(socketURL.path, 0o600)

            guard bound == 0 else {
                let code = errno
                close(descriptor)
                throw AskpassServiceError.cannotBind(socketURL.path, code)
            }
            guard listen(descriptor, 8) == 0 else {
                let code = errno
                close(descriptor)
                throw AskpassServiceError.cannotBind(socketURL.path, code)
            }

            listenDescriptor = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptOne() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            listenDescriptor = -1
            unlink(socketURL.path)
            try? FileManager.default.removeItem(at: socketDirectory)
        }
    }

    /// The variables that make OpenSSH ask this service.
    ///
    /// `SSH_ASKPASS_REQUIRE=force` is the part that matters: without it
    /// OpenSSH uses the terminal whenever it has one, and Termora would never
    /// see the prompt.
    public func environment(forSession token: String, helperPath: String) -> [String: String] {
        [
            "SSH_ASKPASS": helperPath,
            "SSH_ASKPASS_REQUIRE": "force",
            "TERMORA_AUTH_SOCK": socketURL.path,
            "TERMORA_SESSION": token,
            // OpenSSH used to need this. Harmless, and it helps older builds.
            "DISPLAY": "termora",
        ]
    }

    // MARK: - Serving

    private func acceptOne() {
        let client = accept(listenDescriptor, nil, nil)
        guard client >= 0 else { return }

        // A helper that stops talking must not hold a thread.
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let responder else {
            Self.reply(to: client, answer: nil)
            close(client)
            return
        }
        Task.detached { [client] in
            defer { close(client) }
            guard let line = Self.readLine(from: client),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let token = object["session"] as? String,
                  let text = object["prompt"] as? String
            else {
                Self.reply(to: client, answer: nil)
                return
            }
            let answer = await responder(AskpassRequest(sessionToken: token, rawText: text))
            Self.reply(to: client, answer: answer)
        }
    }

    private static func readLine(from descriptor: Int32) -> Data? {
        var received = Data()
        var byte: UInt8 = 0
        while received.count < maximumRequestBytes {
            let count = read(descriptor, &byte, 1)
            if count <= 0 { return received.isEmpty ? nil : received }
            if byte == 0x0A { return received }
            received.append(byte)
        }
        return nil
    }

    private static func reply(to descriptor: Int32, answer: String?) {
        let object: [String: Any] = answer.map { ["ok": true, "answer": $0] } ?? ["ok": false]
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else { return }
        payload.append(0x0A)
        payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let written = write(descriptor, base + sent, buffer.count - sent)
                if written <= 0 { return }
                sent += written
            }
        }
    }
}

public enum AskpassServiceError: Error, LocalizedError {
    case socketPathTooLong(String)
    case cannotCreateSocket(Int32)
    case cannotBind(String, Int32)

    public var errorDescription: String? {
        switch self {
        case let .socketPathTooLong(path):
            "The socket path is too long for a Unix socket: \(path)"
        case let .cannotCreateSocket(code):
            "Termora could not create the password socket. Code \(code)."
        case let .cannotBind(path, code):
            "Termora could not listen at \(path). Code \(code)."
        }
    }
}
