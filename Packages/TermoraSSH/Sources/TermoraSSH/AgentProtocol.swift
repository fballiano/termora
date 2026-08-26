//
//  AgentProtocol.swift
//  TermoraSSH
//
//  This file is compiled into two places: the TermoraSSH library, and the
//  `termora` command-line tool. Keeping one copy means the tool and the
//  tests can never speak different versions of the protocol.
//
//  The protocol is one JSON line each way over a Unix socket:
//
//      request   {"command":"run","bookmark":"web1","words":["uptime"]}
//      reply     {"ok":true,"argv":["/usr/bin/ssh","-S","…"]}  or
//                {"ok":false,"error":"<reason>"}
//
//  No secret ever crosses this socket. A `run` reply carries the argv of an
//  `ssh` command that attaches to an already authenticated control master,
//  and the tool executes that argv itself, so output streams natively and
//  the far exit code comes back untouched.
//
//  The socket helpers below repeat what AskpassClient.swift holds. That is
//  on purpose: each shared file must stand alone, because each tool target
//  compiles only its own files.
//

import Darwin
import Foundation

/// What the `termora` tool asks the application.
public struct AgentRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        case list
        case status
        case run
    }

    public var command: Command
    /// The bookmark name, for `run`.
    public var bookmark: String?
    /// The command words, for `run`. They stay separate words until the
    /// application quotes them for the far shell.
    public var words: [String]?

    public init(command: Command, bookmark: String? = nil, words: [String]? = nil) {
        self.command = command
        self.bookmark = bookmark
        self.words = words
    }
}

/// One bookmark, for `termora list`.
public struct AgentBookmark: Codable, Sendable {
    /// The folder path, for example `Prod / Web`. Empty at the top level.
    public var path: String
    public var name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// One open connection, for `termora status`.
public struct AgentConnectionStatus: Codable, Sendable {
    public var name: String
    public var state: String
    /// How many tunnels are open on the connection.
    public var forwards: Int

    public init(name: String, state: String, forwards: Int) {
        self.name = name
        self.state = state
        self.forwards = forwards
    }
}

/// What the application answers.
public struct AgentReply: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var bookmarks: [AgentBookmark]?
    public var connections: [AgentConnectionStatus]?
    /// The full argv the tool should execute, for `run`.
    public var argv: [String]?

    public init(ok: Bool, error: String? = nil, bookmarks: [AgentBookmark]? = nil,
                connections: [AgentConnectionStatus]? = nil, argv: [String]? = nil) {
        self.ok = ok
        self.error = error
        self.bookmarks = bookmarks
        self.connections = connections
        self.argv = argv
    }

    /// A refusal, with the reason the tool prints on standard error.
    public static func refused(_ reason: String) -> AgentReply {
        AgentReply(ok: false, error: reason)
    }
}

/// Where the socket lives. The application and the tool must agree, so the
/// answer is computed here, in the one shared file.
public enum AgentSocket {
    /// `~/Library/Application Support/Termora/agent/a.sock`. The name is
    /// short, because a Unix socket path may not exceed 104 bytes.
    public static func defaultPath() -> String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Termora/agent/a.sock").path
    }
}

/// The tool's side of the socket.
public enum AgentClient {
    /// Sends one request and waits for the reply. Returns `nil` when the
    /// application is not listening or stops answering.
    ///
    /// The wait is long on purpose: a `run` request may hold until a person
    /// answers the askpass sheet in the application.
    public static func send(
        _ request: AgentRequest,
        socketPath: String,
        timeoutSeconds: Int = 630
    ) -> AgentReply? {
        guard let descriptor = connect(to: socketPath) else { return nil }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        guard var payload = try? JSONEncoder().encode(request) else { return nil }
        payload.append(0x0A)
        guard writeAll(descriptor, payload) else { return nil }

        guard let line = readLine(descriptor) else { return nil }
        return try? JSONDecoder().decode(AgentReply.self, from: line)
    }

    private static func connect(to path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var sent = 0
            while sent < buffer.count {
                let written = write(descriptor, base + sent, buffer.count - sent)
                if written <= 0 { return false }
                sent += written
            }
            return true
        }
    }

    private static func readLine(_ descriptor: Int32) -> Data? {
        var received = Data()
        var byte: UInt8 = 0
        while received.count < 1024 * 1024 {
            let count = read(descriptor, &byte, 1)
            if count <= 0 { return received.isEmpty ? nil : received }
            if byte == 0x0A { return received }
            received.append(byte)
        }
        return nil
    }
}
