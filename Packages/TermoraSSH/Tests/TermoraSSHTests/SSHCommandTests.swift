import Foundation
import Testing
@testable import TermoraModel
@testable import TermoraSSH

private func target(
    host: String = "web01.example.com",
    port: Int = 22,
    _ change: (inout EffectiveSettings) -> Void = { _ in }
) -> SSHTarget {
    var settings = EffectiveSettings.fallback
    settings.username = "root"
    change(&settings)
    return SSHTarget(host: host, port: port, settings: settings)
}

@Test("The master authenticates once and asks for no terminal")
func masterArguments() {
    let arguments = SSHCommand.master(target: target(), controlPath: "/tmp/x.sock")

    #expect(arguments.contains("-M"))
    #expect(arguments.contains("-N"))
    #expect(arguments.contains("-T"))
    #expect(arguments.contains("/tmp/x.sock"))
    #expect(arguments.last == "root@web01.example.com")
    // One prompt only, so a wrong password does not ask three times.
    #expect(arguments.contains("NumberOfPasswordPrompts=1"))
    // The connection must not outlive Termora.
    #expect(arguments.contains("ControlPersist=no"))
}

@Test("A connection with no user name uses the host alone")
func destinationWithoutUsername() {
    let plain = target { $0.username = "" }
    #expect(plain.destination == "web01.example.com")
    #expect(SSHCommand.master(target: plain, controlPath: "/tmp/x.sock").last == "web01.example.com")
}

@Test("A terminal pane attaches to the master and never becomes one")
func sessionAttachesToTheMaster() {
    let arguments = SSHCommand.session(target: target(), controlPath: "/tmp/x.sock")

    #expect(arguments.contains("-S"))
    #expect(arguments.contains("ControlMaster=no"))
    #expect(!arguments.contains("-M"))
    // No port and no options: the master already carries them.
    #expect(!arguments.contains("-p"))
}

@Test("The SFTP channel asks for the subsystem on the same connection")
func sftpArguments() {
    let arguments = SSHCommand.sftpSubsystem(target: target(), controlPath: "/tmp/x.sock")
    #expect(arguments.suffix(2) == ["-s", "sftp"])
    #expect(arguments.contains("ControlMaster=no"))
}

@Test("Each kind of tunnel produces the right flag")
func forwardFlags() {
    let local = PortForward(kind: .local, listenPort: 8080,
                            destinationHost: "localhost", destinationPort: 80)
    #expect(SSHCommand.forwardFlag(local) == ["-L", "8080:localhost:80"])

    let remote = PortForward(kind: .remote, bindAddress: "0.0.0.0", listenPort: 9000,
                             destinationHost: "127.0.0.1", destinationPort: 3000)
    #expect(SSHCommand.forwardFlag(remote) == ["-R", "0.0.0.0:9000:127.0.0.1:3000"])

    let socks = PortForward(kind: .dynamic, listenPort: 1080)
    #expect(SSHCommand.forwardFlag(socks) == ["-D", "1080"])
}

@Test("Adding and cancelling a tunnel uses the control socket, not a new connection")
func forwardControlCommands() {
    let forward = PortForward(kind: .local, listenPort: 8080,
                              destinationHost: "localhost", destinationPort: 80)
    let add = SSHCommand.addForward(forward, target: target(), controlPath: "/tmp/x.sock")
    let cancel = SSHCommand.cancelForward(forward, target: target(), controlPath: "/tmp/x.sock")

    #expect(add.contains("-O") && add.contains("forward"))
    #expect(cancel.contains("-O") && cancel.contains("cancel"))
    #expect(add.contains("ControlMaster=no"))
}

@Test("A password connection asks only for methods that end at a password")
func passwordAuthenticationOptions() {
    let options = SSHCommand.options(for: {
        var settings = EffectiveSettings.fallback
        settings.authentication = .password(Secret("hunter2"))
        return settings
    }())

    #expect(options.contains("PreferredAuthentications=keyboard-interactive,password"))
    #expect(options.contains("PubkeyAuthentication=no"))
    // The secret itself never reaches the command line.
    #expect(!options.contains { $0.contains("hunter2") })
}

@Test("A key connection offers that key only")
func privateKeyOptions() {
    let options = SSHCommand.options(for: {
        var settings = EffectiveSettings.fallback
        settings.authentication = .privateKey(path: "~/.ssh/id_ed25519", passphrase: Secret("x"))
        return settings
    }())

    #expect(options.contains("-i"))
    #expect(options.contains { $0.hasSuffix("/.ssh/id_ed25519") && !$0.hasPrefix("~") })
    #expect(options.contains("IdentitiesOnly=yes"))
    #expect(!options.contains { $0.contains("x'") })
}

@Test("Each host key policy maps to the matching OpenSSH setting")
func hostKeyPolicyOptions() {
    func options(_ policy: HostKeyPolicy) -> [String] {
        var settings = EffectiveSettings.fallback
        settings.hostKeyPolicy = policy
        return SSHCommand.options(for: settings)
    }
    #expect(options(.ask).contains("StrictHostKeyChecking=ask"))
    #expect(options(.strict).contains("StrictHostKeyChecking=yes"))
    #expect(options(.acceptNew).contains("StrictHostKeyChecking=accept-new"))
}

@Test("Settings that are off produce no stray flags")
func optionalFlags() {
    var settings = EffectiveSettings.fallback
    settings.keepAliveSeconds = 0
    settings.agentForwarding = false
    settings.x11Forwarding = false
    settings.jumpHost = ""
    let options = SSHCommand.options(for: settings)

    #expect(!options.contains { $0.hasPrefix("ServerAliveInterval") })
    #expect(!options.contains("ForwardAgent=yes"))
    #expect(!options.contains("ForwardX11=yes"))
    #expect(!options.contains("-J"))
    #expect(options.contains("Compression=no"))

    settings.keepAliveSeconds = 30
    settings.jumpHost = "fab@bastion"
    let more = SSHCommand.options(for: settings)
    #expect(more.contains("ServerAliveInterval=30"))
    #expect(more.contains("-J") && more.contains("fab@bastion"))
}

@Test("A path with a space survives the terminal command line")
func quotingProtectsSpaces() {
    let line = POSIXQuote.line(["/usr/bin/ssh", "-S", "/tmp/a b/c.sock", "root@host"])
    #expect(line == "/usr/bin/ssh -S '/tmp/a b/c.sock' root@host")
    #expect(POSIXQuote.quote("it's") == #"'it'\''s'"#)
    #expect(POSIXQuote.quote("") == "''")
}

// OpenSSH ends its lines with a carriage return and a line feed. Swift counts
// that pair as one Character, so splitting on "\n" alone finds nothing and
// treats the whole log as a single line. These tests hold that behaviour down.
@Test("Output that uses carriage returns is still split into lines")
func splitsCarriageReturnLineFeed() {
    let text = "Warning: Permanently added 'host' to the list of known hosts.\r\n"
        + "fab@host: Permission denied (publickey).\r\n"
    #expect(CommandResult(status: 255, output: "", errorOutput: text).summary
        == "fab@host: Permission denied (publickey).")
}

@Test("A log with only warnings and debug notes counts as a quiet exit")
func quietExitIsRecognised() {
    let noisy = "Warning: Permanently added 'host' to the list of known hosts.\r\n"
        + "debug1: something\r\n"
    #expect(CommandResult(status: 255, output: "", errorOutput: noisy).isQuiet)
    #expect(CommandResult(status: 0, output: "", errorOutput: "").isQuiet)

    let real = noisy + "fab@host: Permission denied (publickey).\r\n"
    #expect(!CommandResult(status: 255, output: "", errorOutput: real).isQuiet)
}

@Test("A warning is never reported as the reason for a failure")
func warningIsNotTheReason() {
    let text = "fab@host: Permission denied (publickey).\r\n"
        + "Warning: Permanently added 'host' to the list of known hosts.\r\n"
    #expect(CommandResult(status: 255, output: "", errorOutput: text).summary
        == "fab@host: Permission denied (publickey).")
}
