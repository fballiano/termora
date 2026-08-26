//
//  UnlockView.swift
//  Termora
//

import SwiftUI
import TermoraVault

/// Asks for the master password of a document that is already chosen.
struct UnlockView: View {
    let url: URL

    @EnvironmentObject private var store: DocumentStore
    @State private var password = ""
    @State private var rememberWithTouchID = false
    @State private var isWorking = false
    /// Counts the refused attempts, so each one shakes the field once.
    @State private var refusals = 0
    @FocusState private var isPasswordFocused: Bool

    private var canUseTouchID: Bool {
        VaultKeyStore.isBiometryAvailable
    }

    private var hasStoredKey: Bool {
        canUseTouchID && store.hasStoredKey(for: url)
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            VStack(spacing: 4) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.title2.weight(.semibold))
                Text(url.deletingLastPathComponent().path)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(spacing: 8) {
                SecureField("Master password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($isPasswordFocused)
                    .onSubmit(unlockWithPassword)
                    .frame(width: 280)
                    .modifier(Shake(animatableData: CGFloat(refusals)))

                // The problem stays under the field, so the next attempt
                // needs no extra click and the focus never leaves.
                if let problem = store.unlockErrorMessage {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 320)
                }
            }

            if canUseTouchID {
                Toggle("Remember this document with Touch ID", isOn: $rememberWithTouchID)
                    .font(.footnote)
                    .frame(width: 280, alignment: .leading)
            }

            VStack(spacing: 8) {
                Button("Unlock", action: unlockWithPassword)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || isWorking)
                    .keyboardShortcut(.defaultAction)

                if hasStoredKey {
                    Button("Use Touch ID") { unlockWithTouchID() }
                        .disabled(isWorking)
                }
            }
            .controlSize(.large)

            Button("Open a different document…") { store.forgetDocument() }
                .buttonStyle(.link)
                .font(.footnote)
        }
        .padding(48)
        .frame(minWidth: 460, minHeight: 420)
        .onAppear {
            isPasswordFocused = true
            // A document that is already trusted opens without a question.
            if hasStoredKey { unlockWithTouchID() }
        }
        .onChange(of: store.unlockErrorMessage) { _, message in
            guard message != nil else { return }
            withAnimation(.linear(duration: 0.4)) { refusals += 1 }
            isPasswordFocused = true
        }
        .onChange(of: password) { _, typed in
            // Typing starts a new attempt, so the old message goes. The
            // guard keeps the message when the field is merely reset after
            // a refusal.
            if !typed.isEmpty { store.unlockErrorMessage = nil }
        }
    }

    private func unlockWithPassword() {
        guard !password.isEmpty else { return }
        isWorking = true
        Task {
            await store.open(at: url, password: password, rememberWithTouchID: rememberWithTouchID)
            password = ""
            isWorking = false
        }
    }

    private func unlockWithTouchID() {
        isWorking = true
        Task {
            await store.openWithStoredKey(at: url)
            isWorking = false
        }
    }
}

/// The macOS login shake: the field slides sideways a few times.
private struct Shake: GeometryEffect {
    /// How far the field travels, in points.
    var travel: CGFloat = 7
    /// How many full swings one refusal makes.
    var swings: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size _: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(animatableData * .pi * swings * 2),
            y: 0
        ))
    }
}
