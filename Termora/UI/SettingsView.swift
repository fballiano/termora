//
//  SettingsView.swift
//  Termora
//

import AppKit
import SwiftUI
import TermoraModel
import TermoraVault
import UniformTypeIdentifiers

/// The Settings window (⌘,): General, Security, Connections.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            SecuritySettingsTab()
                .tabItem { Label("Security", systemImage: "lock") }
            ConnectionsSettingsTab()
                .tabItem { Label("Connections", systemImage: "network") }
        }
        .frame(width: 480)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage(AppSettings.confirmQuitKey) private var confirmQuit = true
    @AppStorage(AppSettings.openLastDocumentKey) private var opensLastDocument = true
    @AppStorage(AppSettings.remoteEditorPathKey) private var remoteEditorPath = ""

    var body: some View {
        Form {
            Toggle("Ask before quitting while connections are open", isOn: $confirmQuit)
            Toggle("Open the last document at launch", isOn: $opensLastDocument)

            Section {
                LabeledContent("Edit remote files with") {
                    HStack(spacing: 8) {
                        Text(editorName)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseEditor() }
                        if !remoteEditorPath.isEmpty {
                            Button("Use Default") { remoteEditorPath = "" }
                        }
                    }
                }
            } footer: {
                Text("A double-click in the file browser copies the file to this "
                    + "Mac, opens it here, and copies each save back.")
            }
        }
        .formStyle(.grouped)
    }

    private var editorName: String {
        guard let url = AppSettings.remoteEditorURL else {
            return "The default application"
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func chooseEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose the application that opens remote files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        remoteEditorPath = url.path
    }
}

// MARK: - Security

private struct SecuritySettingsTab: View {
    @EnvironmentObject private var store: DocumentStore
    @AppStorage(AppSettings.autoLockMinutesKey) private var autoLockMinutes = 0
    @AppStorage(AppSettings.lockOnSleepKey) private var locksOnSleep = false

    @State private var isChangingPassword = false
    /// Mirrors whether a stored key exists, read from disk on appearance and
    /// after every action, so the toggle never guesses.
    @State private var touchIDIsOn = false
    @State private var touchIDProblem: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Master password") {
                    Button("Change…") { isChangingPassword = true }
                }
                .disabled(!store.isUnlocked)

                Toggle("Unlock this document with Touch ID", isOn: touchIDBinding)
                    .disabled(!store.isUnlocked || !VaultKeyStore.isBiometryAvailable)

                Button("Forget Stored Key") {
                    store.forgetTouchIDKey()
                    refresh()
                }
                .disabled(!touchIDIsOn)

                if let touchIDProblem {
                    Label(touchIDProblem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("This document")
            } footer: {
                if !store.isUnlocked {
                    Text("Open a document to change its password or Touch ID.")
                }
            }

            Section("Lock") {
                Picker("Lock after", selection: $autoLockMinutes) {
                    Text("Never").tag(0)
                    Text("5 minutes of rest").tag(5)
                    Text("15 minutes of rest").tag(15)
                    Text("60 minutes of rest").tag(60)
                }
                Toggle("Lock when the Mac sleeps", isOn: $locksOnSleep)
                Text("Locking closes every open session and its tunnels.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .sheet(isPresented: $isChangingPassword) {
            ChangePasswordSheet()
                .onDisappear { refresh() }
        }
    }

    private var touchIDBinding: Binding<Bool> {
        Binding(
            get: { touchIDIsOn },
            set: { wantsOn in
                if wantsOn {
                    touchIDProblem = store.enableTouchID()
                } else {
                    store.forgetTouchIDKey()
                    touchIDProblem = nil
                }
                refresh()
            }
        )
    }

    private func refresh() {
        touchIDIsOn = store.isTouchIDEnabled
    }
}

/// Asks for the current password once, then the new one twice.
private struct ChangePasswordSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var repeatedPassword = ""
    @State private var problem: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change the master password")
                .font(.headline)
            Text("The document is sealed again with the new password. "
                + "The old password stops working everywhere.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            SecureField("Current password", text: $currentPassword)
            SecureField("New password", text: $newPassword)
            SecureField("New password again", text: $repeatedPassword)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isWorking ? "Changing…" : "Change Password") { change() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isWorking
                            || currentPassword.isEmpty
                            || newPassword.isEmpty
                            || newPassword != repeatedPassword
                    )
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 400)
    }

    private func change() {
        isWorking = true
        problem = nil
        Task {
            if let failure = await store.changeMasterPassword(
                current: currentPassword, to: newPassword
            ) {
                problem = failure
                isWorking = false
            } else {
                dismiss()
            }
        }
    }
}

// MARK: - Connections

private struct ConnectionsSettingsTab: View {
    @AppStorage(AppSettings.defaultHostKeyPolicyKey)
    private var hostKeyPolicy = HostKeyPolicy.ask.rawValue
    @AppStorage(AppSettings.defaultKeepAliveKey)
    private var keepAliveSeconds = EffectiveSettings.fallback.keepAliveSeconds
    @AppStorage(AppSettings.connectTimeoutKey)
    private var connectTimeoutSeconds = 180

    var body: some View {
        Form {
            Section {
                Picker("Unknown host key", selection: $hostKeyPolicy) {
                    Text("Ask me").tag(HostKeyPolicy.ask.rawValue)
                    Text("Refuse an unknown key").tag(HostKeyPolicy.strict.rawValue)
                    Text("Accept a new key").tag(HostKeyPolicy.acceptNew.rawValue)
                }
                Stepper(value: $keepAliveSeconds, in: 0 ... 600, step: 15) {
                    LabeledContent(
                        "Keep-alive interval",
                        value: keepAliveSeconds == 0 ? "Off" : "\(keepAliveSeconds) s"
                    )
                }
            } footer: {
                Text("These apply when no folder or bookmark sets a value.")
            }

            Section {
                Stepper(value: $connectTimeoutSeconds, in: 10 ... 600, step: 10) {
                    LabeledContent(
                        "Give up connecting after",
                        value: "\(connectTimeoutSeconds) s"
                    )
                }
            } footer: {
                Text("The wait covers authentication, so leave room "
                    + "to type a password or touch a security key.")
            }
        }
        .formStyle(.grouped)
    }
}
