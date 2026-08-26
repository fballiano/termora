import Foundation
import Testing
@testable import TermoraModel
@testable import TermoraSFTP
@testable import TermoraSSH

/// The whole stack: a real OpenSSH server, one control master, and the SFTP
/// client speaking the protocol on a channel of that same connection.
///
/// This is what the file browser does. Nothing authenticates twice.
@MainActor
@Suite(.serialized, .enabled(if: TestSSHServer.isAvailable))
final class SFTPOverSSHTests {
    private let server: TestSSHServer
    private let helperPath: String
    private let engine: SSHEngine
    private let workspace: URL

    init() throws {
        server = try TestSSHServer()
        helperPath = try TestAskpassHelper.build()
        engine = try SSHEngine(helperPath: helperPath)

        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termora-sftp-ssh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    deinit {
        server.shutDown()
        try? FileManager.default.removeItem(atPath: helperPath)
        try? FileManager.default.removeItem(at: workspace)
    }

    private func connect() async throws -> SSHConnection {
        var settings = EffectiveSettings.fallback
        settings.username = server.username
        settings.authentication = .privateKey(path: server.plainKeyPath, passphrase: Secret(""))
        settings.hostKeyPolicy = .acceptNew
        settings.keepAliveSeconds = 0

        let connection = await engine.connect(id: UUID(), name: "files", target: SSHTarget(
            host: "127.0.0.1", port: server.port,
            settings: settings, extraOptions: server.isolationOptions
        ))
        try #require(connection.state == .connected, "Log: \(connection.log)")
        return connection
    }

    private func makeClient(on connection: SSHConnection) async throws -> SFTPClient {
        let client = SFTPClient(transport: SFTPProcessTransport(
            executable: SSHCommand.executable,
            arguments: connection.sftpArguments()
        ))
        try await client.start()
        return client
    }

    @Test("The browser lists, uploads, and downloads over the live connection")
    func fullRoundTripOverSSH() async throws {
        let connection = try await connect()
        let client = try await makeClient(on: connection)

        // The far host answers with a real path, not a relative one.
        let home = try await client.realPath(".")
        #expect(home.hasPrefix("/"))

        // Put a file there, and read the folder back.
        var payload = Data()
        for index in 0 ..< 120_000 { payload.append(UInt8(index % 251)) }
        let source = workspace.appendingPathComponent("payload.bin")
        try payload.write(to: source)

        let remotePath = SFTPClient.join(workspace.path, "uploaded.bin")
        try await client.upload(source, to: remotePath)

        let listing = try await client.listDirectory(workspace.path)
        #expect(listing.map(\.name).sorted() == ["payload.bin", "uploaded.bin"])
        let uploaded = try #require(listing.first { $0.name == "uploaded.bin" })
        #expect(uploaded.size == UInt64(payload.count))

        // And bring it back, byte for byte.
        let destination = workspace.appendingPathComponent("returned.bin")
        try await client.download(remotePath, to: destination)
        #expect(try Data(contentsOf: destination) == payload)

        await client.stop()
        // The connection itself is untouched by opening and closing files.
        #expect(connection.state == .connected)
        await engine.disconnect(id: connection.id)
    }

    @Test("Files and a terminal pane share one connection at the same time")
    func filesAndTerminalTogether() async throws {
        let connection = try await connect()
        let client = try await makeClient(on: connection)

        // A pane runs while the file channel is open.
        let paneResult = await ProcessRunner.run(
            SSHCommand.executable,
            SSHCommand.session(target: connection.target, controlPath: connection.controlPath)
                + ["echo", "pane-alive"]
        )
        #expect(paneResult.output.contains("pane-alive"))

        // And the file channel still answers afterwards.
        let listing = try await client.listDirectory(workspace.path)
        #expect(listing.isEmpty)

        await client.stop()
        // Closing the files must not take the terminal down with it.
        let afterClose = await ProcessRunner.run(
            SSHCommand.executable,
            SSHCommand.session(target: connection.target, controlPath: connection.controlPath)
                + ["echo", "still-alive"]
        )
        #expect(afterClose.output.contains("still-alive"),
                "Closing the file browser must leave the connection alone.")

        await engine.disconnect(id: connection.id)
    }
}
