//
//  AskpassClient.swift
//  TermoraSSH
//
//  This file is compiled into two places: the TermoraSSH library, and the
//  `termora-askpass` command-line tool. Keeping one copy means the tool and
//  the tests can never speak different versions of the protocol.
//
//  The protocol is one JSON line each way over a Unix socket:
//
//      request   {"session":"<token>","prompt":"<text>"}
//      reply     {"ok":true,"answer":"<text>"}  or  {"ok":false}
//

import Darwin
import Foundation

public enum AskpassClient {
    /// Asks Termora for an answer. Returns `nil` when the socket is missing,
    /// the token is unknown, or the person cancelled.
    public static func ask(socketPath: String, token: String, prompt: String) -> String? {
        guard let descriptor = connect(to: socketPath) else { return nil }
        defer { close(descriptor) }

        let request: [String: String] = ["session": token, "prompt": prompt]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        payload.append(0x0A)
        guard writeAll(descriptor, payload) else { return nil }

        guard let line = readLine(descriptor),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["ok"] as? Bool == true,
              let answer = object["answer"] as? String
        else { return nil }
        return answer
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
        while received.count < 64 * 1024 {
            let count = read(descriptor, &byte, 1)
            if count <= 0 { return received.isEmpty ? nil : received }
            if byte == 0x0A { return received }
            received.append(byte)
        }
        return nil
    }
}
