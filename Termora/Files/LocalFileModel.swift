//
//  LocalFileModel.swift
//  Termora
//

import AppKit
import Foundation

/// The folder on this Mac, shown beside the folder on the far host.
///
/// Two panes side by side make a copy a drag from one to the other, which is
/// how a file manager works and how Royal TSX works.
@MainActor
final class LocalFileModel: ObservableObject {
    struct Item: Identifiable, Hashable, Sendable {
        let url: URL
        let name: String
        let isDirectory: Bool
        let size: UInt64
        let modifiedAt: Date?

        var id: String { url.path }
    }

    @Published private(set) var directory: URL
    @Published private(set) var items: [Item] = []
    @Published var selection: Set<String> = []
    @Published var errorMessage: String?
    /// Hidden files stay hidden until you ask for them, as in Finder.
    @Published var showsHiddenFiles = false {
        didSet { reload() }
    }

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.directory = directory
        reload()
    }

    var canGoUp: Bool { directory.path != "/" }

    var selectedItems: [Item] {
        items.filter { selection.contains($0.id) }
    }

    func reload() {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                      .isHiddenKey]
        do {
            let contents = try manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: showsHiddenFiles ? [] : [.skipsHiddenFiles]
            )
            items = contents.map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Item(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: values?.isDirectory ?? false,
                    size: UInt64(values?.fileSize ?? 0),
                    modifiedAt: values?.contentModificationDate
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            selection = []
        } catch {
            errorMessage = "Termora could not read \(directory.path). \(error.localizedDescription)"
            items = []
        }
    }

    func go(to url: URL) {
        directory = url
        reload()
    }

    func goUp() {
        guard canGoUp else { return }
        go(to: directory.deletingLastPathComponent())
    }

    func open(_ item: Item) {
        if item.isDirectory {
            go(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            selectedItems.isEmpty ? [directory] : selectedItems.map(\.url)
        )
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = directory
        panel.message = "Choose the folder to show on this side."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        go(to: url)
    }

    /// Items the table asked to move to the Trash. The view asks first.
    @Published var trashRequest: [Item] = []

    /// Removes the chosen items, after the view has asked.
    func moveToTrash(_ chosen: [Item]) {
        for item in chosen {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            } catch {
                errorMessage = "Termora could not move \(item.name) to the Trash. "
                    + error.localizedDescription
                break
            }
        }
        reload()
    }

    func makeFolder(named name: String) {
        guard !name.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name), withIntermediateDirectories: false
            )
            reload()
        } catch {
            errorMessage = "Termora could not make that folder. \(error.localizedDescription)"
        }
    }
}
