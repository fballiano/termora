//
//  InspectorView.swift
//  Termora
//

import SwiftUI
import TermoraModel

/// Edits the selected folder or connection.
struct InspectorView: View {
    @EnvironmentObject private var store: DocumentStore

    var body: some View {
        Group {
            if let connection = store.selectedConnection {
                ConnectionInspector(connection: connection)
                    .id(connection.id)
            } else if let folder = store.selectedFolder {
                FolderInspector(folder: folder)
                    .id(folder.id)
            } else {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "sidebar.left",
                    description: Text("Choose a connection or a folder in the sidebar.")
                )
            }
        }
        .frame(minWidth: 380)
    }
}

// MARK: - Connection

private struct ConnectionInspector: View {
    @EnvironmentObject private var store: DocumentStore
    let connection: Connection

    /// Edits are held here. A change starts a short countdown, and one save
    /// writes the file when the typing pauses: the whole document is
    /// encrypted on every save, so a save per keystroke is real work.
    @State private var draft: Connection
    @State private var portText: String
    @State private var pendingCommit: Task<Void, Never>?

    init(connection: Connection) {
        self.connection = connection
        _draft = State(initialValue: connection)
        _portText = State(initialValue: String(connection.port))
    }

    private var portProblem: String? {
        guard let value = Int(portText), (1 ... 65535).contains(value) else {
            return "The port must be a number between 1 and 65535."
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorSection("Connection") {
                    LabeledRow("Name") { TextField("", text: $draft.name) }
                    LabeledRow("Host") {
                        TextField("host.example.com", text: $draft.host)
                    }
                    LabeledRow("Port") {
                        TextField("22", text: $portText)
                            .frame(width: 80)
                            .onChange(of: portText) { _, new in
                                guard let value = Int(new),
                                      (1 ... 65535).contains(value) else { return }
                                draft.port = value
                            }
                    }
                    // The field keeps the last good value, so the problem is
                    // said instead of fixed quietly.
                    if let portProblem {
                        Label(portProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.leading, 138)
                    }
                    LabeledRow("Favorite") {
                        Toggle("", isOn: $draft.isFavorite).labelsHidden()
                    }
                }

                Divider()
                SettingsEditor(settings: $draft.settings, parentID: draft.parentID)

                Divider()
                ForwardsEditor(forwards: $draft.forwards, connectionID: draft.id)

                Divider()
                InspectorSection("Notes") {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 70)
                        .font(.body)
                        .border(.quaternary)
                }
            }
            .padding(18)
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: draft) { _, new in
            pendingCommit?.cancel()
            pendingCommit = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                commit(new)
            }
        }
        .onDisappear {
            // The countdown may still be running. Nothing may be lost.
            pendingCommit?.cancel()
            commit(draft)
        }
    }

    private func commit(_ new: Connection) {
        // Nothing changed, nothing saved. The disappearing sheet commits
        // once more, and that call must not write the file again.
        guard store.index.connection(new.id) != new else { return }
        store.update { document in
            guard let at = document.connections.firstIndex(where: { $0.id == new.id })
            else { return }
            document.connections[at] = new
        }
    }
}

// MARK: - Folder

private struct FolderInspector: View {
    @EnvironmentObject private var store: DocumentStore
    let folder: Folder
    @State private var draft: Folder
    @State private var pendingCommit: Task<Void, Never>?

    init(folder: Folder) {
        self.folder = folder
        _draft = State(initialValue: folder)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorSection("Folder") {
                    LabeledRow("Name") { TextField("", text: $draft.name) }
                }

                Text("Every connection inside this folder uses these values, "
                     + "unless it sets its own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()
                SettingsEditor(settings: $draft.settings, parentID: draft.parentID)

                Divider()
                InspectorSection("Notes") {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 70)
                        .border(.quaternary)
                }
            }
            .padding(18)
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: draft) { _, new in
            pendingCommit?.cancel()
            pendingCommit = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                commit(new)
            }
        }
        .onDisappear {
            pendingCommit?.cancel()
            commit(draft)
        }
    }

    private func commit(_ new: Folder) {
        guard store.index.folder(new.id) != new else { return }
        store.update { document in
            guard let at = document.folders.firstIndex(where: { $0.id == new.id })
            else { return }
            document.folders[at] = new
        }
    }
}

// MARK: - The inherited settings, shared by both inspectors

private struct SettingsEditor: View {
    @EnvironmentObject private var store: DocumentStore
    @Binding var settings: NodeSettings
    let parentID: UUID?

    private var effective: EffectiveSettings {
        store.index.effectiveSettings(of: settings, under: parentID)
    }

    private func source<Value>(_ keyPath: KeyPath<NodeSettings, Inherited<Value>>) -> String? {
        store.index.sourceFolder(of: keyPath, in: settings, under: parentID)?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Credentials").font(.headline)

            InheritedRow(
                title: "User name",
                setting: $settings.username,
                inheritedValue: effective.username,
                sourceFolderName: source(\.username),
                describe: { $0.isEmpty ? "not set" : $0 }
            ) { value in
                TextField("root", text: value)
            }

            InheritedRow(
                title: "Authentication",
                setting: $settings.authentication,
                inheritedValue: effective.authentication,
                sourceFolderName: source(\.authentication),
                describe: \.kindName
            ) { value in
                AuthenticationEditor(authentication: value)
            }

            // Not "Connection": the sheet already has a section of that
            // name, for the host and the port.
            Text("SSH options").font(.headline).padding(.top, 6)

            InheritedRow(
                title: "Jump host",
                setting: $settings.jumpHost,
                inheritedValue: effective.jumpHost,
                sourceFolderName: source(\.jumpHost),
                describe: { $0.isEmpty ? "none" : $0 }
            ) { value in
                TextField("user@bastion.example.com", text: value)
            }

            InheritedRow(
                title: "Host key",
                setting: $settings.hostKeyPolicy,
                inheritedValue: effective.hostKeyPolicy,
                sourceFolderName: source(\.hostKeyPolicy),
                describe: { policy in
                    switch policy {
                    case .ask: "Ask me"
                    case .strict: "Refuse an unknown key"
                    case .acceptNew: "Accept a new key"
                    }
                }
            ) { value in
                Picker("", selection: value) {
                    Text("Ask me").tag(HostKeyPolicy.ask)
                    Text("Refuse an unknown key").tag(HostKeyPolicy.strict)
                    Text("Accept a new key").tag(HostKeyPolicy.acceptNew)
                }
                .labelsHidden()
            }

            InheritedRow(
                title: "Keep alive",
                setting: $settings.keepAliveSeconds,
                inheritedValue: effective.keepAliveSeconds,
                sourceFolderName: source(\.keepAliveSeconds),
                describe: { $0 == 0 ? "off" : "every \($0) s" }
            ) { value in
                Stepper("\(value.wrappedValue) s", value: value, in: 0 ... 3600, step: 15)
                    .fixedSize()
            }

            InheritedRow(
                title: "Agent forwarding",
                setting: $settings.agentForwarding,
                inheritedValue: effective.agentForwarding,
                sourceFolderName: source(\.agentForwarding),
                describe: { $0 ? "on" : "off" }
            ) { value in
                Toggle("", isOn: value).labelsHidden()
            }

            InheritedRow(
                title: "Compression",
                setting: $settings.compression,
                inheritedValue: effective.compression,
                sourceFolderName: source(\.compression),
                describe: { $0 ? "on" : "off" }
            ) { value in
                Toggle("", isOn: value).labelsHidden()
            }

            InheritedRow(
                title: "X11 forwarding",
                setting: $settings.x11Forwarding,
                inheritedValue: effective.x11Forwarding,
                sourceFolderName: source(\.x11Forwarding),
                describe: { $0 ? "on" : "off" }
            ) { value in
                Toggle("", isOn: value).labelsHidden()
            }

            Text("After connecting").font(.headline).padding(.top, 6)

            InheritedRow(
                title: "Type this",
                setting: $settings.afterConnectText,
                inheritedValue: effective.afterConnectText,
                sourceFolderName: source(\.afterConnectText),
                describe: { $0.isEmpty ? "nothing" : $0 }
            ) { value in
                TextField("cd /opt/maho/app{ENTER}", text: value)
            }

            Text("Termora types this into the session once it opens. Use "
                 + "{ENTER}, {TAB}, {ESC}, the arrow names, and {DELAY:500} to wait.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 138)

            Text("Before connecting").font(.headline).padding(.top, 6)

            InheritedRow(
                title: "Run this",
                setting: $settings.beforeConnect,
                inheritedValue: effective.beforeConnect,
                sourceFolderName: source(\.beforeConnect),
                describe: { $0.isEmpty ? "nothing" : $0.name }
            ) { value in
                LocalCommandEditor(command: value)
            }

            Text("Termora runs this on this Mac before it opens the connection. "
                 + "Use $URI$, $PORT$, $USERNAME$ and $NAME$ in the arguments. "
                 + "A password must never go on a command line.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 138)

            Text("Appearance").font(.headline).padding(.top, 6)

            InheritedRow(
                title: "Color",
                setting: $settings.colorTag,
                inheritedValue: effective.colorTag,
                sourceFolderName: source(\.colorTag),
                describe: { $0 == .none ? "none" : $0.rawValue.capitalized }
            ) { value in
                Picker("", selection: value) {
                    ForEach(ColorTag.allCases, id: \.self) { tag in
                        Text(tag == .none ? "None" : tag.rawValue.capitalized).tag(tag)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
        .environment(\.inheritToggleLabel, parentID == nil ? "Use default" : "Inherit")
    }
}

/// Edits the command that runs on this Mac before a connection opens.
private struct LocalCommandEditor: View {
    @Binding var command: LocalCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $command.name)
            TextField("/usr/local/bin/open-firewall.sh", text: $command.launchPath)
            TextField("Arguments, for example $URI$", text: $command.arguments)
            Toggle("Wait for it to finish", isOn: $command.waitsForCompletion)
                .controlSize(.small)
        }
    }
}

/// Chooses the authentication method and shows only the fields it needs.
private struct AuthenticationEditor: View {
    @Binding var authentication: Authentication

    private enum Kind: String, CaseIterable, Identifiable {
        case sshConfig, agent, password, privateKey
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sshConfig: "Let OpenSSH decide"
            case .agent: "ssh-agent"
            case .password: "Password"
            case .privateKey: "Private key"
            }
        }
    }

    private var kind: Kind {
        switch authentication {
        case .sshConfig: .sshConfig
        case .agent: .agent
        case .password: .password
        case .privateKey: .privateKey
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // An explicit closure here, not `set: change`. A method reference
            // makes the Swift 6.3.3 compiler crash while it generates code
            // for the thunk. See the note in the project README.
            Picker("", selection: Binding(get: { kind }, set: { newKind in change(to: newKind) })) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()

            switch authentication {
            case let .password(secret):
                SecureField("Password", text: Binding(
                    get: { secret.value },
                    set: { authentication = .password(Secret($0)) }
                ))
            case let .privateKey(path, passphrase):
                TextField("~/.ssh/id_ed25519", text: Binding(
                    get: { path },
                    set: { authentication = .privateKey(path: $0, passphrase: passphrase) }
                ))
                SecureField("Passphrase, if the key has one", text: Binding(
                    get: { passphrase.value },
                    set: { authentication = .privateKey(path: path, passphrase: Secret($0)) }
                ))
            case .agent, .sshConfig:
                EmptyView()
            }
        }
    }

    private func change(to newKind: Kind) {
        // Keep what the old method held, so switching back does not lose it.
        switch newKind {
        case .sshConfig: authentication = .sshConfig
        case .agent: authentication = .agent
        case .password: authentication = .password(authentication.secret ?? .empty)
        case .privateKey:
            if case let .privateKey(path, passphrase) = authentication {
                authentication = .privateKey(path: path, passphrase: passphrase)
            } else {
                authentication = .privateKey(path: "", passphrase: .empty)
            }
        }
    }
}

// MARK: - Small helpers

private struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .frame(width: 130, alignment: .trailing)
                .foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled block in the inspector.
private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}
