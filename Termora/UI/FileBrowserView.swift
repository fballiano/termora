//
//  FileBrowserView.swift
//  Termora
//

import SwiftUI
import TermoraSFTP

/// The file browser of one connection.
struct FileBrowserView: View {
    @ObservedObject var model: FileBrowserModel
    @StateObject private var local = LocalFileModel()
    @State private var isAskingNewFolder = false
    @State private var newFolderName = ""
    @State private var isConfirmingTrash = false
    @State private var doomed: [LocalFileModel.Item] = []
    @State private var renaming: SFTPEntry?
    @State private var newName = ""
    @State private var isConfirmingDelete = false
    /// The share of the width the local pane takes.
    @State private var splitRatio = 0.5

    var body: some View {
        VStack(spacing: 0) {
            switch model.state {
            case .opening:
                centred { ProgressView("Opening the files…") }
            case let .failed(reason):
                centred {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 30))
                            .foregroundStyle(.orange)
                        Text("Termora could not open the files.")
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            case .ready:
                // Not `HSplitView`: see the note on `SplitContainer`.
                SplitContainer(axis: .horizontal, ratio: $splitRatio) {
                    LocalPane(model: local, onReceive: { _ in })
                } second: {
                    VStack(spacing: 0) {
                        toolbar
                        Divider()
                        listing
                    }
                }
                if let transfer = model.transfer {
                    Divider()
                    progressBar(transfer)
                }
            }
        }
        .task { await model.open() }
        .onDisappear { model.close() }
        .alert("Termora", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("New folder", isPresented: $isAskingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await model.makeFolder(named: name) }
            }
        }
        .onChange(of: model.renameRequest) { _, request in
            guard let request else { return }
            newName = request.name
            renaming = request
            model.renameRequest = nil
        }
        .onChange(of: model.deleteRequest) { _, request in
            guard !request.isEmpty else { return }
            isConfirmingDelete = true
            model.deleteRequest = []
        }
        .alert("Rename", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let entry = renaming {
                    let name = newName
                    Task { await model.rename(entry, to: name) }
                }
                renaming = nil
            }
        }
        .confirmationDialog(
            deleteQuestion,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let chosen = model.selectedEntries
                Task { await model.delete(chosen) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. The items are removed on the far host.")
        }
    }

    private var deleteQuestion: String {
        let chosen = model.selectedEntries
        return chosen.count == 1
            ? "Delete \(chosen[0].name)?"
            : "Delete \(chosen.count) items?"
    }

    // MARK: - Parts

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.goUp() }
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(!model.canGoUp)
            .help("Go to the folder above")

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Read the folder again")

            VStack(alignment: .leading, spacing: 0) {
                Text("Far host").font(.caption2).foregroundStyle(.tertiary)
                Text(model.currentPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.isBusy { ProgressView().controlSize(.small) }

            Button {
                isAskingNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New folder")

            Button {
                Task { await model.chooseFilesToUpload() }
            } label: {
                Image(systemName: "arrow.up.doc")
            }
            .help("Copy files to the far host")

            Button {
                let chosen = model.selectedEntries
                Task { await model.download(chosen) }
            } label: {
                Image(systemName: "arrow.down.doc")
            }
            .disabled(model.selection.isEmpty)
            .help("Copy the chosen files to this Mac")

            Button {
                isConfirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.selection.isEmpty)
            .help("Delete the chosen items on the far host")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var listing: some View {
        RemoteFileTable(model: model)
    }

    private func progressBar(_ transfer: FileBrowserModel.Transfer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.isUpload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(.tint)
            Text(transfer.name).lineLimit(1)
            ProgressView(value: transfer.fraction)
                .frame(maxWidth: 220)
            Text("\(sizeText(transfer.done)) of \(sizeText(transfer.total))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let files = transfer.fileCount {
                Text(files)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func centred(@ViewBuilder _ content: () -> some View) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Small helpers

    private func icon(for entry: SFTPEntry) -> String {
        if entry.isDirectory { return "folder" }
        if entry.isSymbolicLink { return "arrow.triangle.turn.up.right.circle" }
        return "doc"
    }

    private func sizeText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// The folder on this Mac, on the left of the browser.
private struct LocalPane: View {
    @ObservedObject var model: LocalFileModel
    let onReceive: (Int) -> Void
    @State private var isAskingNewFolder = false
    @State private var newFolderName = ""
    @State private var isConfirmingTrash = false
    @State private var doomed: [LocalFileModel.Item] = []

    private var trashQuestion: String {
        doomed.count == 1
            ? "Move \"\(doomed[0].name)\" to the Trash?"
            : "Move \(doomed.count) items to the Trash?"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(!model.canGoUp)
                    .help("Go to the folder above")

                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Read the folder again")

                VStack(alignment: .leading, spacing: 0) {
                    Text("This Mac").font(.caption2).foregroundStyle(.tertiary)
                    Text(model.directory.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { model.choose() } label: { Image(systemName: "folder") }
                    .help("Choose another folder")

                Button { isAskingNewFolder = true } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("New folder")

                Button { model.showsHiddenFiles.toggle() } label: {
                    Image(systemName: model.showsHiddenFiles ? "eye" : "eye.slash")
                }
                .help(model.showsHiddenFiles ? "Hide hidden files" : "Show hidden files")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()
            LocalFileTable(model: model, onReceive: onReceive)
        }
        .alert("New folder", isPresented: $isAskingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                model.makeFolder(named: name)
            }
        }
        .alert("Termora", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // The table only asks. Nothing leaves this Mac's folder until you say so.
        .onChange(of: model.trashRequest) { _, request in
            guard !request.isEmpty else { return }
            doomed = request
            isConfirmingTrash = true
            model.trashRequest = []
        }
        .confirmationDialog(
            trashQuestion,
            isPresented: $isConfirmingTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                let chosen = doomed
                doomed = []
                model.moveToTrash(chosen)
            }
            Button("Cancel", role: .cancel) { doomed = [] }
        } message: {
            Text("You can put them back from the Trash.")
        }
    }
}
