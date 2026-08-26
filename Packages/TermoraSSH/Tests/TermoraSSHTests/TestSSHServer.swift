import Foundation
@testable import TermoraSSH

/// A throwaway OpenSSH server for the integration tests.
///
/// The server runs as you, on a high port, from its own directory. It touches
/// nothing in your home folder: its own host key, its own authorized_keys, and
/// the clients use `UserKnownHostsFile` inside the same directory.
/// Marked `@unchecked Sendable` so that the nonisolated `deinit` of a
/// `@MainActor` test suite can still shut the server down. Only one test runs
/// at a time, because the suite is serialized.
final class TestSSHServer: @unchecked Sendable {
    let directory: URL
    let port: Int
    let plainKeyPath: String
    let lockedKeyPath: String
    /// The passphrase on `lockedKeyPath`.
    let passphrase = "the key passphrase"
    let username = NSUserName()

    private var process: Process?

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd")
    }

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termora-sshd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        port = Int.random(in: 21000 ... 60000)
        plainKeyPath = directory.appendingPathComponent("plain_key").path
        lockedKeyPath = directory.appendingPathComponent("locked_key").path

        let hostKey = directory.appendingPathComponent("host_key").path
        try Self.keygen(path: hostKey, passphrase: "")
        try Self.keygen(path: plainKeyPath, passphrase: "")
        try Self.keygen(path: lockedKeyPath, passphrase: passphrase)

        let authorized = try String(contentsOfFile: plainKeyPath + ".pub", encoding: .utf8)
            + (try String(contentsOfFile: lockedKeyPath + ".pub", encoding: .utf8))
        let authorizedPath = directory.appendingPathComponent("authorized_keys").path
        try authorized.write(toFile: authorizedPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedPath)

        let configuration = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey)
        AuthorizedKeysFile \(authorizedPath)
        PidFile \(directory.appendingPathComponent("sshd.pid").path)
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        Subsystem sftp /usr/libexec/sftp-server
        """
        let configurationPath = directory.appendingPathComponent("sshd_config").path
        try configuration.write(toFile: configurationPath, atomically: true, encoding: .utf8)

        let sshd = Process()
        sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        sshd.arguments = ["-f", configurationPath, "-D", "-e"]
        sshd.standardError = Pipe()
        sshd.standardOutput = Pipe()
        try sshd.run()
        process = sshd

        guard waitUntilListening() else {
            throw NSError(domain: "TestSSHServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The test server did not start on port \(port).",
            ])
        }
    }

    deinit { shutDown() }

    func shutDown() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Options that keep the test away from your own `~/.ssh` files.
    var isolationOptions: [String] {
        [
            "-o", "UserKnownHostsFile=\(directory.appendingPathComponent("known_hosts").path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "IdentityAgent=none",
        ]
    }

    private func waitUntilListening() -> Bool {
        for _ in 0 ..< 100 {
            if isPortOpen() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func isPortOpen() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func keygen(path: String, passphrase: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-f", path, "-N", passphrase, "-C", "termora-test"]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
    }
}

/// Builds `termora-askpass` from its own sources, so the integration test does
/// not depend on an Xcode build having run first.
enum TestAskpassHelper {
    static func build() throws -> String {
        // #filePath is Packages/TermoraSSH/Tests/TermoraSSHTests/<this file>.
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TermoraSSHTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TermoraSSH
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // the repository root
        let main = sourceDirectory.appendingPathComponent("Tools/termora-askpass/main.swift").path
        let client = sourceDirectory
            .appendingPathComponent("Packages/TermoraSSH/Sources/TermoraSSH/AskpassClient.swift").path

        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termora-askpass-\(UUID().uuidString.prefix(8))").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-O", main, client, "-o", output]
        // Keep the environment, so TMPDIR still points at a directory this
        // process may write to. Remove only the variables that `swift test`
        // exports for its own compile, which make a nested compile disagree
        // with itself.
        var environment = ProcessInfo.processInfo.environment
        for key in ["SDKROOT", "DEVELOPER_DIR", "TOOLCHAINS", "SWIFT_EXEC",
                    "SWIFT_FRONTEND_EXEC", "LD", "CC", "CXX", "PLATFORM_NAME"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = "swiftc exited with \(process.terminationStatus). "
                + String(decoding: errorData, as: UTF8.self)
                + String(decoding: outputData, as: UTF8.self)
            throw NSError(domain: "TestAskpassHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        return output
    }
}
