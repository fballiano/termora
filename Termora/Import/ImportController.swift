//
//  ImportController.swift
//  Termora
//

import AppKit
import Foundation
import SwiftUI
import TermoraImport
import TermoraModel
import UniformTypeIdentifiers

/// Runs a Royal TSX import and reports what happened.
@MainActor
final class ImportController: ObservableObject {
    enum Stage: Equatable {
        case choosing
        case reading
        /// Asking Royal TSX for the decrypted secrets.
        case fetchingSecrets(done: Int, total: Int)
        case finished(ImportReport)
        case failed(String)
    }

    @Published var isPresented = false
    @Published private(set) var stage: Stage = .choosing
    @Published var sourceURL: URL?
    @Published var options = ImportOptions()
    @Published var askRoyalForSecrets = true

    private let store: DocumentStore

    init(store: DocumentStore) {
        self.store = store
    }

    var isRoyalInstalled: Bool { RoyalTSXBridge.isInstalled }

    var isWorking: Bool {
        switch stage {
        case .reading, .fetchingSecrets: true
        default: false
        }
    }

    func begin() {
        stage = .choosing
        sourceURL = nil
        isPresented = true
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose your Royal TSX document."
        panel.allowedContentTypes = ["rtsz", "rtsx"].compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceURL = url
    }

    /// Reads the document, collects the secrets, and adds everything to the
    /// open Termora document. Nothing already in the document is removed.
    func run() async {
        guard let sourceURL else { return }
        stage = .reading

        let objects: [RoyalObject]
        do {
            objects = try RoyalDocumentParser().parse(contentsOf: sourceURL)
        } catch {
            stage = .failed(error.localizedDescription)
            return
        }

        var secrets = RoyalImporter.RecoveredSecrets()
        if askRoyalForSecrets, RoyalTSXBridge.isInstalled {
            secrets = await fetchSecrets(for: objects, documentPath: sourceURL.path)
        }

        // Royal TSX keeps the commands of a task in its settings file, not in
        // the connections document. Read them, so a task comes across whole.
        let tasks = (try? RoyalTaskLibrary.read()) ?? .empty

        let (imported, report) = RoyalImporter(options: options, tasks: tasks)
            .makeDocument(from: objects, secrets: secrets)

        store.update { document in
            document.folders.append(contentsOf: imported.folders)
            document.connections.append(contentsOf: imported.connections)
        }
        stage = .finished(report)
    }

    /// Asks Royal TSX for one secret at a time, so the sheet can show progress.
    private func fetchSecrets(
        for objects: [RoyalObject],
        documentPath: String
    ) async -> RoyalImporter.RecoveredSecrets {
        let bridge = RoyalTSXBridge()
        let carriers = objects.filter {
            $0.type == "RoyalSSHConnection"
                && ($0["CredentialPassword"] != nil || $0["CredentialPassphrase"] != nil)
        }
        guard !carriers.isEmpty else { return .none }

        stage = .fetchingSecrets(done: 0, total: carriers.count)
        // Royal TSX must hold the same document open to answer.
        guard bridge.openDocument(path: documentPath) == .ready else { return .none }

        var secrets = RoyalImporter.RecoveredSecrets()
        for (offset, object) in carriers.enumerated() {
            if object["CredentialPassword"] != nil {
                let value = bridge.value(ofKey: "CredentialPassword", objectID: object.id)
                if !value.isEmpty { secrets.passwords[object.id] = value }
            }
            if object["CredentialPassphrase"] != nil {
                let value = bridge.value(ofKey: "CredentialPassphrase", objectID: object.id)
                if !value.isEmpty { secrets.passphrases[object.id] = value }
            }
            stage = .fetchingSecrets(done: offset + 1, total: carriers.count)
            // Let the sheet redraw between questions.
            await Task.yield()
        }
        return secrets
    }
}
