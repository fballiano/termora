//
//  WelcomeView.swift
//  Termora
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The first screen. It appears until a document is chosen.
struct WelcomeView: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var isCreating = false
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Termora").font(.largeTitle.weight(.semibold))
                Text("Keep your SSH connections in one encrypted document.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Button("Create a document…") { isCreating = true }
                    .buttonStyle(.borderedProminent)
                Button("Open a document…") { openExisting() }
            }
            .controlSize(.large)

            if !store.recentDocumentURLs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    ForEach(store.recentDocumentURLs, id: \.path) { url in
                        Button {
                            store.chooseDocument(at: url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tint)
                                Text(url.deletingPathExtension().lastPathComponent)
                                Text(url.deletingLastPathComponent().path)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(url.path)
                    }
                }
                .frame(maxWidth: 380)
            }

            Text("The document holds your bookmarks and your secrets. "
                 + "A master password protects it. Put the file wherever you sync your files. "
                 + "You can also drop a document on this window.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(48)
        .frame(minWidth: 520, minHeight: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 2)
                .padding(6)
        }
        // A document dropped on the window opens, the way it would in Finder.
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in store.chooseDocument(at: url) }
            }
            return true
        }
        .sheet(isPresented: $isCreating) { CreateDocumentSheet() }
    }

    private func openExisting() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.termoraDocument, UTType.data]
        panel.message = "Choose a Termora document."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.chooseDocument(at: url)
    }
}

/// Asks for a location and a master password, then creates the document.
struct CreateDocumentSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var url: URL?
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isWorking = false

    private var problem: String? {
        if url == nil { return "Choose where to save the document." }
        if password.count < 8 { return "Use at least 8 characters." }
        if password != confirmation { return "The two passwords are different." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New document").font(.title2.weight(.semibold))

            HStack {
                Text(url?.path ?? "No location chosen")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                Spacer()
                Button("Choose…") { chooseLocation() }
            }

            SecureField("Master password", text: $password)
            SecureField("Repeat the master password", text: $confirmation)

            Text("Termora cannot recover this password. Nobody can open the "
                 + "document without it.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let problem, !password.isEmpty || url != nil {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || isWorking)
            }
        }
        .padding(24)
        .frame(width: 460)
        .textFieldStyle(.roundedBorder)
    }

    private func chooseLocation() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Connections.termora"
        panel.allowedContentTypes = [UTType.termoraDocument]
        panel.message = "Where should Termora keep your document?"
        guard panel.runModal() == .OK else { return }
        url = panel.url
    }

    private func create() {
        guard let url else { return }
        isWorking = true
        Task {
            await store.create(at: url, password: password)
            isWorking = false
            dismiss()
        }
    }
}

extension UTType {
    /// The document type of Termora. The file starts with `TERMORA1`.
    static let termoraDocument = UTType(exportedAs: "com.fabrizioballiano.termora.document")
}
