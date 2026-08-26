//
//  PromptSheets.swift
//  Termora
//

import SwiftUI
import TermoraSSH

/// Shows the question that OpenSSH asked, and sends the answer back.
///
/// The sheet must always answer, even when it is dismissed, or the connection
/// would wait for ever.
struct PromptSheet: View {
    @ObservedObject var request: PromptRequest
    let onFinish: () -> Void

    @State private var answer = ""
    @FocusState private var isAnswerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch request.prompt {
            case .password:
                header(icon: "key.fill", title: "Password for \(request.connectionName)")
                SecureField("Password", text: $answer)
                    .focused($isAnswerFocused)
                    .onSubmit { finish(with: answer) }

            case let .keyPassphrase(keyPath):
                header(icon: "key.fill", title: "Passphrase for the private key")
                if !keyPath.isEmpty {
                    Text(keyPath)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                SecureField("Passphrase", text: $answer)
                    .focused($isAnswerFocused)
                    .onSubmit { finish(with: answer) }

            case let .hostKey(details):
                header(icon: "exclamationmark.shield.fill",
                       title: "Check the host key of \(request.connectionName)")
                Text(details)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                Text("Accept the key only if this fingerprint matches the one you "
                     + "expect. A fingerprint that changed can mean somebody is "
                     + "listening.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case let .other(text):
                header(icon: "questionmark.circle.fill", title: request.connectionName)
                Text(text)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                TextField("Answer", text: $answer)
                    .focused($isAnswerFocused)
                    .onSubmit { finish(with: answer) }
            }

            HStack {
                Spacer()
                Button("Cancel") { finish(with: nil) }
                    .keyboardShortcut(.cancelAction)

                if case .hostKey = request.prompt {
                    Button("Refuse") { finish(with: "no") }
                    Button("Accept") { finish(with: "yes") }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Send") { finish(with: answer) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(answer.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .textFieldStyle(.roundedBorder)
        .onAppear { isAnswerFocused = true }
        .interactiveDismissDisabled()
    }

    private func header(icon: String, title: String) -> some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
    }

    private func finish(with value: String?) {
        request.respond(value)
        answer = ""
        onFinish()
    }
}
