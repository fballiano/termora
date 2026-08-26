//
//  RoyalImporter.swift
//  TermoraImport
//

import Foundation
import TermoraModel

/// Choices that change what the import keeps.
public struct ImportOptions: Hashable, Sendable {
    /// What to keep when a Royal entry holds both a private key and a password.
    ///
    /// Termora gives a connection one authentication method. Royal lets an
    /// entry carry a key and a password at the same time, and six entries in a
    /// typical document do. Choose which one survives; the report names every
    /// entry this touched, with the value that was left out.
    public enum BothCredentials: String, Hashable, Sendable, CaseIterable {
        /// Keep the password, and name the key file in the report.
        /// Nothing secret is lost, because a key path is not a secret.
        case keepPassword
        /// Keep the key file, and say in the report that a password was left out.
        case keepPrivateKey
    }

    public var whenBothCredentialsExist: BothCredentials

    public init(whenBothCredentialsExist: BothCredentials = .keepPassword) {
        self.whenBothCredentialsExist = whenBothCredentialsExist
    }
}

/// Turns Royal TSX objects into a Termora document.
public struct RoyalImporter {
    /// Royal writes `CredentialMode` as a number.
    private enum CredentialMode: Int {
        case none = 0
        /// Take the credentials from the folder above.
        case inherited = 1
        /// The entry carries its own credentials.
        case own = 2
    }

    public let options: ImportOptions
    /// The task commands, read from the Royal TSX settings file.
    public let tasks: RoyalTaskLibrary

    public init(options: ImportOptions = ImportOptions(),
                tasks: RoyalTaskLibrary = .empty) {
        self.options = options
        self.tasks = tasks
    }

    /// Royal writes an identifier of all zeros to mean "nothing".
    public static func isRealIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.contains { $0 != "0" && $0 != "-" }
    }

    /// Secrets that Royal TSX handed over, keyed by the Royal object ID.
    public struct RecoveredSecrets: Sendable {
        public var passwords: [String: String]
        public var passphrases: [String: String]

        public init(passwords: [String: String] = [:], passphrases: [String: String] = [:]) {
            self.passwords = passwords
            self.passphrases = passphrases
        }

        public static let none = RecoveredSecrets()
        public var count: Int { passwords.count + passphrases.count }
    }

    public func makeDocument(
        from objects: [RoyalObject],
        secrets: RecoveredSecrets = .none
    ) -> (document: Document, report: ImportReport) {
        var report = ImportReport()

        // Royal joins objects by its own text IDs. Give every one a new UUID,
        // and keep a map so ParentID still points at the right folder.
        var identifiers: [String: UUID] = [:]
        for object in objects where object.type == "RoyalFolder" || object.type == "RoyalSSHConnection" {
            identifiers[object.id] = UUID()
        }

        // A child of the document object sits at the top level.
        let rootIDs = Set(objects.filter { $0.type == "RoyalDocument" }.map(\.id))
        // Everything under the trash stays deleted.
        let trashed = trashedIDs(in: objects)

        var document = Document()

        for object in objects {
            guard let id = identifiers[object.id] else { continue }
            if trashed.contains(object.id) {
                report.skip(object.name, "This entry is in the Royal TSX trash.")
                continue
            }
            let parent = rootIDs.contains(object.parentID) ? nil : identifiers[object.parentID]

            switch object.type {
            case "RoyalFolder":
                document.add(Folder(
                    id: id,
                    parentID: parent,
                    name: object.name.isEmpty ? "Folder" : object.name,
                    position: object.int("PositionNr") ?? 0,
                    isExpanded: object.bool("IsExpanded", default: true),
                    settings: settings(from: object, secrets: secrets, report: &report)
                ))
                report.foldersCreated += 1

            case "RoyalSSHConnection":
                guard let connection = makeConnection(
                    object, id: id, parent: parent, secrets: secrets, report: &report
                ) else { continue }
                document.add(connection)
                report.connectionsCreated += 1

            default:
                break
            }
        }

        report.secretsRecovered = secrets.count
        document.renumberPositions()
        return (document, report)
    }

    // MARK: - Connections

    private func makeConnection(
        _ object: RoyalObject,
        id: UUID,
        parent: UUID?,
        secrets: RecoveredSecrets,
        report: inout ImportReport
    ) -> Connection? {
        let name = object.name.isEmpty ? object.string("URI") : object.name

        if object.bool("IsTelnetConnection") {
            report.skip(name, "Telnet is not supported.")
            return nil
        }
        if object.bool("IsSerialPortConnection") {
            report.skip(name, "A serial port is not supported.")
            return nil
        }
        if object.bool("IsConnectionTemplate") {
            report.skip(name, "This is a Royal TSX template, not a connection.")
            return nil
        }

        let host = object.string("URI")
        if host.isEmpty {
            report.needsSecret(name, "This entry has no host name. Fill it in before you connect.")
        }

        var notes = object.string("Description")
        let sequence = object.string("KeySequence")
        if !sequence.isEmpty, !object.bool("KeySequenceEnabled") {
            let line = "Key sequence, switched off in Royal TSX: \(sequence)"
            notes = notes.isEmpty ? line : notes + "\n\n" + line
        }

        let connection = Connection(
            id: id,
            parentID: parent,
            name: name.isEmpty ? "Connection" : name,
            position: object.int("PositionNr") ?? 0,
            host: host,
            port: object.int("Port") ?? 22,
            isFavorite: object.bool("Favorite"),
            settings: settings(from: object, secrets: secrets, report: &report),
            notes: notes
        )

        // A Royal secure gateway is a jump host.
        let gateway = object.string("SecureGatewayID")
        if RoyalImporter.isRealIdentifier(gateway), connection.settings.jumpHost.inheritsFromParent {
            report.note(name, "This entry uses a Royal TSX secure gateway. "
                        + "Set the jump host by hand.")
        }

        // A key sequence that Royal wrote out is kept. One that only names an
        // object in another document cannot be, because the text is not here.
        if !object.string("KeySequenceName").isEmpty,
           object.string("KeySequence").isEmpty {
            report.note(name, "The key sequence \"\(object.string("KeySequenceName"))\" "
                        + "is kept in another Royal TSX document, so its text is not in "
                        + "this file. Type it in if you need it.")
        }
        if !object.string("KeySequence").isEmpty, !object.bool("KeySequenceEnabled") {
            report.note(name, "A key sequence was switched off in Royal TSX. "
                        + "Termora left it off. The text is in the notes.")
        }

        // Termora runs a task before connecting. It does not run one after
        // disconnecting yet, so say so instead of dropping it quietly.
        let afterName = object.string("PostDisconnectTaskName")
        if !afterName.isEmpty || RoyalImporter.isRealIdentifier(object.string("PostDisconnectTaskId")) {
            let shown = afterName.isEmpty ? "a task" : "the task \"\(afterName)\""
            report.note(name, "Royal TSX runs \(shown) after disconnecting. "
                        + "Termora does not run a command after disconnecting.")
        }

        return connection
    }

    // MARK: - Settings and inheritance

    private func settings(
        from object: RoyalObject,
        secrets: RecoveredSecrets,
        report: inout ImportReport
    ) -> NodeSettings {
        var settings = NodeSettings.inheritAll
        let name = object.name

        // Royal keeps a flag and a mode. Either one asking for the parent
        // means the value is inherited.
        let mode = CredentialMode(rawValue: object.int("CredentialMode") ?? 0) ?? .none
        let inheritsCredentials = object.bool("CredentialFromParent") || mode == .inherited

        if !inheritsCredentials {
            let username = object.string("CredentialUsername")
            if !username.isEmpty { settings.username = .value(username) }

            if let method = authentication(from: object, secrets: secrets,
                                           name: name, report: &report) {
                settings.authentication = .value(method)
            }
        }

        // Royal writes `ColorFromParent` as False to mean "this entry keeps
        // its own colour". An entry that says so and has no colour has no
        // colour at all, so it must not take the colour of its folder.
        if object["ColorFromParent"] != nil, !object.bool("ColorFromParent") {
            settings.colorTag = .value(colorTag(from: object) ?? .none)
        }

        // These have no `FromParent` flag in Royal, so a value present on the
        // object is a value it sets.
        if let interval = object.int("KeepAliveInterval") {
            settings.keepAliveSeconds = .value(max(0, interval))
        }
        if object["SSHAllowAgentForwarding"] != nil {
            settings.agentForwarding = .value(object.bool("SSHAllowAgentForwarding"))
        }
        if object["SSHEnableCompression"] != nil {
            settings.compression = .value(object.bool("SSHEnableCompression"))
        }
        if object["SSHEnableX11Forwarding"] != nil {
            settings.x11Forwarding = .value(object.bool("SSHEnableX11Forwarding"))
        }
        if object["WarnFingerprintMismatch"] != nil {
            settings.hostKeyPolicy = .value(object.bool("WarnFingerprintMismatch") ? .ask : .acceptNew)
        }

        // Royal names a task, but keeps its commands in the settings file.
        // The library holds those commands, so the task can come across whole.
        if !object.bool("PreConnectTaskFromParent") {
            settings.beforeConnect = preConnectCommand(for: object, name: name, report: &report)
        }

        // Royal writes the text of a key sequence straight into the entry, in
        // the same form Termora uses, so it comes across as it stands.
        if !object.bool("KeySequenceFromParent") {
            let sequence = object.string("KeySequence")
            if !sequence.isEmpty, object.bool("KeySequenceEnabled") {
                settings.afterConnectText = .value(sequence)
            }
        }

        return settings
    }

    /// Turns the task a Royal entry asks for into a command Termora can run.
    private func preConnectCommand(
        for object: RoyalObject,
        name: String,
        report: inout ImportReport
    ) -> Inherited<LocalCommand> {
        let wantedName = object.string("PreConnectTaskName")
        let wantedID = object.string("PreConnectTaskId")
        guard !wantedName.isEmpty || RoyalImporter.isRealIdentifier(wantedID) else {
            return .inherit
        }

        guard let task = tasks.preConnectTask(for: object) else {
            let shown = wantedName.isEmpty ? "a task" : "the task \"\(wantedName)\""
            report.note(name, "Royal TSX runs \(shown) before connecting. "
                        + "Termora did not find its commands in the Royal TSX settings "
                        + "file, so it did not import the task.")
            return .inherit
        }

        // A command line is readable by every process on this Mac. A task that
        // asks for a password must not become one.
        let full = task.commandLine + " " + task.arguments
        if CommandPlaceholders.containsSecretMark(full) {
            report.note(name, "The task \"\(task.name)\" puts a password on its "
                        + "command line. Termora did not import it, because a command "
                        + "line is readable by every program on this Mac.")
            return .inherit
        }

        var command = task.command
        command.waitsForCompletion = object.bool("PreConnectTaskWait", default: true)
        return .value(command)
    }

    private func authentication(
        from object: RoyalObject,
        secrets: RecoveredSecrets,
        name: String,
        report: inout ImportReport
    ) -> Authentication? {
        let keyPath = object.string("PrivateKeyPath").isEmpty
            ? object.string("CredentialKeyFile")
            : object.string("PrivateKeyPath")
        let hasStoredPassword = object["CredentialPassword"] != nil
        let hasStoredPassphrase = object["CredentialPassphrase"] != nil

        let password = secrets.passwords[object.id] ?? ""
        let passphrase = secrets.passphrases[object.id] ?? ""

        switch (keyPath.isEmpty, hasStoredPassword) {
        case (true, true):
            if password.isEmpty {
                report.needsSecret(name, "Royal TSX did not hand over the password. Type it in.")
            }
            return .password(Secret(password))

        case (true, false):
            // No key and no password: let OpenSSH use the agent or ~/.ssh/config.
            return .sshConfig

        case (false, false):
            if hasStoredPassphrase, passphrase.isEmpty {
                report.needsSecret(name, "Royal TSX did not hand over the key passphrase. Type it in.")
            }
            return .privateKey(path: keyPath, passphrase: Secret(passphrase))

        case (false, true):
            // Royal held both. Termora keeps one, so the choice is yours.
            switch options.whenBothCredentialsExist {
            case .keepPassword:
                if password.isEmpty {
                    report.needsSecret(name, "Royal TSX did not hand over the password. Type it in.")
                }
                report.note(name, "This entry also used the key \(keyPath). "
                            + "Termora kept the password. Change the method if you prefer the key.")
                return .password(Secret(password))
            case .keepPrivateKey:
                report.note(name, "This entry also had a stored password. "
                            + "Termora kept the key \(keyPath). Type the password in if you need it.")
                return .privateKey(path: keyPath, passphrase: Secret(passphrase))
            }
        }
    }

    /// Royal writes a colour as `#RRGGBB`. Termora keeps a small set of names,
    /// so the nearest one is chosen.
    private func colorTag(from object: RoyalObject) -> ColorTag? {
        let hex = object.string("Color")
        guard hex.hasPrefix("#"), hex.count == 7 else { return nil }
        let digits = hex.dropFirst()
        guard let value = Int(digits, radix: 16) else { return nil }

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255

        let palette: [(ColorTag, Double, Double, Double)] = [
            (.red, 1, 0.23, 0.19),
            (.orange, 1, 0.58, 0),
            (.yellow, 1, 0.8, 0),
            (.green, 0.2, 0.78, 0.35),
            (.blue, 0, 0.48, 1),
            (.purple, 0.69, 0.32, 0.87),
            (.grey, 0.56, 0.56, 0.58),
        ]
        return palette.min {
            distance($0, red, green, blue) < distance($1, red, green, blue)
        }?.0
    }

    private func distance(
        _ entry: (ColorTag, Double, Double, Double),
        _ red: Double, _ green: Double, _ blue: Double
    ) -> Double {
        let dr = entry.1 - red, dg = entry.2 - green, db = entry.3 - blue
        return dr * dr + dg * dg + db * db
    }

    /// Every object inside the Royal TSX trash, however deeply nested.
    private func trashedIDs(in objects: [RoyalObject]) -> Set<String> {
        var doomed = Set(objects.filter { $0.type == "RoyalTrash" }.map(\.id))
        guard !doomed.isEmpty else { return [] }

        // Repeat until nothing new is found, so a folder in the trash takes
        // everything below it.
        var changed = true
        var rounds = 0
        while changed, rounds < 128 {
            changed = false
            rounds += 1
            for object in objects
            where !doomed.contains(object.id) && doomed.contains(object.parentID) {
                doomed.insert(object.id)
                changed = true
            }
        }
        return doomed
    }
}
