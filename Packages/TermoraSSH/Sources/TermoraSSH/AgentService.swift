//
//  AgentService.swift
//  TermoraSSH
//

import Darwin
import Foundation

/// Answers the `termora` command-line tool.
///
/// The service listens on a Unix socket at a fixed, known place, so the tool
/// can find it without any configuration. The socket file is 0600 inside a
/// 0700 directory, which is the same protection that `ssh-agent` relies on:
/// only processes running as you can reach it.
///
/// The service holds no secret and makes no decision. It hands each request
/// to the responder and writes back what the responder returns. The
/// application starts the service when a document unlocks and stops it when
/// the document locks, so a locked document answers nothing.
public final class AgentService: @unchecked Sendable {
    public typealias Responder = @Sendable (AgentRequest) async -> AgentReply

    public let socketURL: URL

    private let responderLock = NSLock()
    private var storedResponder: Responder?
    private let queue = DispatchQueue(label: "com.fabrizioballiano.Termora.agent")
    private var listenDescriptor: Int32 = -1
    private var source: DispatchSourceRead?

    private static let maximumRequestBytes = 1024 * 1024

    /// Set this before `start()`. It is held behind a lock, because a request
    /// arrives on the socket queue.
    public var responder: Responder? {
        get { responderLock.withLock { storedResponder } }
        set { responderLock.withLock { storedResponder = newValue } }
    }

    public init(socketPath: String = AgentSocket.defaultPath()) throws {
        socketURL = URL(fileURLWithPath: socketPath)
        guard socketURL.path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw AskpassServiceError.socketPathTooLong(socketURL.path)
        }
    }

    deinit { stop() }

    // MARK: - Lifetime

    public func start() throws {
        try queue.sync {
            guard listenDescriptor < 0 else { return }

            // The directory keeps everyone else out, whatever the socket's
            // own mode ends up being.
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            // A socket file left behind by a crash would block the bind.
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
            guard bound == 0 else {
                let code = errno
                close(descriptor)
                throw AskpassServiceError.cannotBind(socketURL.path, code)
            }
            chmod(socketURL.path, 0o600)
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
        }
    }

    // MARK: - Serving

    private func acceptOne() {
        let client = accept(listenDescriptor, nil, nil)
        guard client >= 0 else { return }

        // The read timeout guards only the request line. The reply may come
        // much later, because a `run` request waits for the connection and,
        // when OpenSSH must ask, for a person.
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let responder else {
            Self.reply(to: client, with: .refused("Termora is not ready."))
            close(client)
            return
        }
        Task.detached { [client] in
            defer { close(client) }
            guard let line = Self.readLine(from: client),
                  let request = try? JSONDecoder().decode(AgentRequest.self, from: line)
            else {
                Self.reply(to: client, with: .refused("The request was not understood."))
                return
            }
            Self.reply(to: client, with: await responder(request))
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

    private static func reply(to descriptor: Int32, with reply: AgentReply) {
        guard var payload = try? JSONEncoder().encode(reply) else { return }
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
