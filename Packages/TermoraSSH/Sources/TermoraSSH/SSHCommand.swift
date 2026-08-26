//
//  SSHCommand.swift
//  TermoraSSH
//

import Foundation
import TermoraModel

/// Everything the SSH engine needs about one connection, after inheritance.
public struct SSHTarget: Hashable, Sendable {
    public var host: String
    public var port: Int
    public var settings: EffectiveSettings
    /// Extra `ssh` options for this connection, for example
    /// `["-o", "UserKnownHostsFile=/dev/null"]`. They are added last, so they
    /// win over the options that the settings produce.
    public var extraOptions: [String]

    public init(host: String, port: Int, settings: EffectiveSettings,
                extraOptions: [String] = []) {
        self.host = host
        self.port = port
        self.settings = settings
        self.extraOptions = extraOptions
    }

    /// `user@host`, or just `host` when no user name is set.
    public var destination: String {
        settings.username.isEmpty ? host : "\(settings.username)@\(host)"
    }
}

/// Builds the `ssh` command lines.
///
/// Termora never speaks the SSH protocol itself. It drives `/usr/bin/ssh`, so
/// it inherits `~/.ssh/config`, certificates, FIDO keys, agent support, and
/// `known_hosts` without writing any of that again.
///
/// One control master carries the whole connection. Every later action
/// attaches to its socket and therefore needs no second authentication.
public enum SSHCommand {
    public static let executable = "/usr/bin/ssh"

    // MARK: - The control master

    /// The long-lived process that authenticates once and carries everything.
    ///
    /// `-M` makes it a master, `-N` asks for no command, and `-T` asks for no
    /// terminal. `ControlPersist=no` ties the connection to this process, so
    /// quitting Termora closes it rather than leaving it behind.
    public static func master(target: SSHTarget, controlPath: String) -> [String] {
        var arguments = [
            "-M", "-N", "-T",
            "-S", controlPath,
            "-o", "ControlPersist=no",
            // One prompt only. Without this a wrong password is asked for
            // three times, and each attempt reaches the person again.
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ExitOnForwardFailure=yes",
        ]
        arguments += ["-p", String(target.port)]
        arguments += options(for: target.settings)
        arguments += target.extraOptions
        arguments.append(target.destination)
        return arguments
    }

    /// A terminal pane. It attaches to the master, so it opens at once.
    public static func session(target: SSHTarget, controlPath: String) -> [String] {
        attach(to: controlPath) + [target.destination]
    }

    /// The SFTP subsystem, on a channel of the same connection.
    /// The pipe carries the raw SFTP protocol.
    public static func sftpSubsystem(target: SSHTarget, controlPath: String) -> [String] {
        attach(to: controlPath) + [target.destination, "-s", "sftp"]
    }

    /// Adds a tunnel to a live connection, without reconnecting.
    public static func addForward(_ forward: PortForward, target: SSHTarget, controlPath: String) -> [String] {
        attach(to: controlPath) + ["-O", "forward"] + forwardFlag(forward) + [target.destination]
    }

    public static func cancelForward(_ forward: PortForward, target: SSHTarget, controlPath: String) -> [String] {
        attach(to: controlPath) + ["-O", "cancel"] + forwardFlag(forward) + [target.destination]
    }

    /// Asks whether the master is alive.
    public static func check(target: SSHTarget, controlPath: String) -> [String] {
        attach(to: controlPath) + ["-O", "check", target.destination]
    }

    /// Closes the master and everything on it.
    public static func exit(target: SSHTarget, controlPath: String) -> [String] {
        attach(to: controlPath) + ["-O", "exit", target.destination]
    }

    // MARK: - Parts

    private static func attach(to controlPath: String) -> [String] {
        ["-S", controlPath, "-o", "ControlMaster=no"]
    }

    /// The options that come from the resolved settings of the connection.
    static func options(for settings: EffectiveSettings) -> [String] {
        var arguments: [String] = []

        switch settings.hostKeyPolicy {
        case .ask:
            arguments += ["-o", "StrictHostKeyChecking=ask"]
        case .strict:
            arguments += ["-o", "StrictHostKeyChecking=yes"]
        case .acceptNew:
            // OpenSSH records a new key by itself and still refuses a changed
            // one, so nobody has to answer a question that has one safe answer.
            arguments += ["-o", "StrictHostKeyChecking=accept-new"]
        }

        switch settings.authentication {
        case .sshConfig:
            break
        case .agent:
            arguments += ["-o", "PreferredAuthentications=publickey"]
        case .password:
            // Offer the two methods that end at a password prompt. The prompt
            // then reaches Termora through the askpass helper.
            arguments += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
            arguments += ["-o", "PubkeyAuthentication=no"]
        case let .privateKey(path, _):
            let expanded = (path as NSString).expandingTildeInPath
            if !expanded.isEmpty {
                arguments += ["-i", expanded]
                // Use this key and nothing the agent happens to hold, so the
                // server does not refuse after too many wrong keys.
                arguments += ["-o", "IdentitiesOnly=yes"]
            }
            arguments += ["-o", "PreferredAuthentications=publickey"]
        }

        if !settings.jumpHost.isEmpty {
            arguments += ["-J", settings.jumpHost]
        }
        if settings.keepAliveSeconds > 0 {
            arguments += ["-o", "ServerAliveInterval=\(settings.keepAliveSeconds)"]
            arguments += ["-o", "ServerAliveCountMax=3"]
        }
        arguments += ["-o", "Compression=\(settings.compression ? "yes" : "no")"]
        if settings.agentForwarding { arguments += ["-o", "ForwardAgent=yes"] }
        if settings.x11Forwarding { arguments += ["-o", "ForwardX11=yes"] }

        return arguments
    }

    /// `-L 8080:localhost:80`, `-R …`, or `-D 1080`.
    static func forwardFlag(_ forward: PortForward) -> [String] {
        let bind = forward.bindAddress.isEmpty ? "" : "\(forward.bindAddress):"
        switch forward.kind {
        case .local:
            return ["-L", "\(bind)\(forward.listenPort):\(forward.destinationHost):\(forward.destinationPort)"]
        case .remote:
            return ["-R", "\(bind)\(forward.listenPort):\(forward.destinationHost):\(forward.destinationPort)"]
        case .dynamic:
            return ["-D", "\(bind)\(forward.listenPort)"]
        }
    }
}
