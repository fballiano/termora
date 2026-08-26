//
//  RemoteFileTable.swift
//  Termora
//

import AppKit
import SwiftUI
import TermoraSFTP
import UniformTypeIdentifiers

/// Carries a closure that AppKit gave us across to the main actor.
///
/// AppKit predates the checks, so its callbacks are not marked as safe to
/// send. This one is called once, from one place, which is why the box is
/// safe here.
private struct Handoff<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The list of remote files.
///
/// This is an `NSTableView` rather than a SwiftUI `Table` for one reason:
/// dragging several rows to Finder at once. Finder expects an
/// `NSFilePromiseProvider` per dragged item, and only AppKit can hand it one
/// for every selected row. A promise also means nothing is copied while you
/// drag: the copy starts when you let go.
struct RemoteFileTable: NSViewRepresentable {
    @ObservedObject var model: FileBrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openChosenRow(_:))

        for column in Coordinator.Column.allCases {
            let item = NSTableColumn(identifier: column.identifier)
            item.title = column.title
            item.width = column.width
            item.minWidth = column.minimumWidth
            table.addTableColumn(item)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.menu = context.coordinator.makeMenu()

        // Files dragged in from Finder land in the folder on screen.
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.model = model
        guard let table = scrollView.documentView as? NSTableView else { return }
        if context.coordinator.shownEntries != model.entries {
            context.coordinator.shownEntries = model.entries
            table.reloadData()
        }
        context.coordinator.applySelectionFromModel(to: table)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
        NSFilePromiseProviderDelegate {
        enum Column: CaseIterable {
            case name, size, changed, rights

            var identifier: NSUserInterfaceItemIdentifier {
                NSUserInterfaceItemIdentifier(rawValue: title)
            }

            var title: String {
                switch self {
                case .name: "Name"
                case .size: "Size"
                case .changed: "Changed"
                case .rights: "Rights"
                }
            }

            var width: CGFloat {
                switch self {
                case .name: 280
                case .size: 90
                case .changed: 150
                case .rights: 90
                }
            }

            var minimumWidth: CGFloat { self == .name ? 120 : 60 }
        }

        var model: FileBrowserModel
        var shownEntries: [SFTPEntry] = []
        weak var table: NSTableView?
        /// The queue Finder uses to ask for each promised file. It is
        /// nonisolated because the promise callbacks do not run on the main
        /// actor.
        private nonisolated let promiseQueue = OperationQueue()

        init(model: FileBrowserModel) {
            self.model = model
            super.init()
            promiseQueue.name = "com.fabrizioballiano.Termora.filePromise"
        }

        // MARK: - Rows

        func numberOfRows(in tableView: NSTableView) -> Int { shownEntries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let tableColumn, shownEntries.indices.contains(row) else { return nil }
            let entry = shownEntries[row]

            let cell = NSTableCellView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text

            var leading: CGFloat = 2
            if tableColumn.identifier == Column.name.identifier {
                let image = NSImageView()
                image.image = NSImage(systemSymbolName: icon(for: entry), accessibilityDescription: nil)
                image.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                ])
                leading = 24
            }
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            switch tableColumn.identifier {
            case Column.name.identifier:
                text.stringValue = entry.name
                cell.toolTip = entry.path
            case Column.size.identifier:
                text.stringValue = entry.isDirectory
                    ? "—"
                    : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
                text.textColor = .secondaryLabelColor
                text.alignment = .right
            case Column.changed.identifier:
                text.stringValue = entry.modifiedAt.map {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .short
                    return formatter.string(from: $0)
                } ?? ""
                text.textColor = .secondaryLabelColor
            default:
                text.stringValue = entry.attributes.permissionsText
                text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                text.textColor = .secondaryLabelColor
            }
            return cell
        }

        private func icon(for entry: SFTPEntry) -> String {
            if entry.isDirectory { return "folder" }
            if entry.isSymbolicLink { return "arrow.triangle.turn.up.right.circle" }
            return "doc"
        }

        // MARK: - Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            let chosen = table.selectedRowIndexes
                .compactMap { shownEntries.indices.contains($0) ? shownEntries[$0].path : nil }
            model.selection = Set(chosen)
        }

        func applySelectionFromModel(to table: NSTableView) {
            let wanted = IndexSet(shownEntries.enumerated()
                .filter { model.selection.contains($0.element.path) }
                .map(\.offset))
            if wanted != table.selectedRowIndexes {
                table.selectRowIndexes(wanted, byExtendingSelection: false)
            }
        }

        @objc func openChosenRow(_ sender: Any?) {
            guard let table, table.clickedRow >= 0,
                  shownEntries.indices.contains(table.clickedRow)
            else { return }
            let entry = shownEntries[table.clickedRow]
            Task { await model.open(entry) }
        }

        // MARK: - Dragging out

        /// One promise per selected row. Finder asks each for its file when
        /// the drag is let go, so a drag of ten rows copies ten items.
        func tableView(_ tableView: NSTableView,
                       pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard shownEntries.indices.contains(row),
                  let promise = SFTPPromise.descriptor(for: shownEntries[row])
            else { return nil }

            let provider = NSFilePromiseProvider(
                fileType: promise.typeIdentifier, delegate: self
            )
            // The name and the path travel with the promise, because Finder
            // asks for them on a thread that cannot reach the model.
            provider.userInfo = promise.userInfo
            return provider
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                             fileNameForType fileType: String) -> String {
            SFTPPromise.fileName(from: filePromiseProvider.userInfo) ?? "file"
        }

        nonisolated func operationQueue(
            for filePromiseProvider: NSFilePromiseProvider
        ) -> OperationQueue {
            promiseQueue
        }

        nonisolated func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping ((any Error)?) -> Void
        ) {
            guard let path = SFTPPromise.path(from: filePromiseProvider.userInfo) else {
                completionHandler(SFTPError.channelClosed)
                return
            }
            // AppKit hands over a plain closure, so it is boxed to cross to
            // the main actor.
            let finish = Handoff(completionHandler)
            // The copy starts here, when the drag has been let go, and lands
            // exactly where the system asked for it.
            Task { @MainActor in
                guard let entry = self.shownEntries.first(where: { $0.path == path }) else {
                    finish.value(SFTPError.channelClosed)
                    return
                }
                do {
                    try await self.model.copy(entry, to: url)
                    finish.value(nil)
                } catch {
                    self.model.errorMessage = "Termora could not copy \(entry.name). "
                        + error.localizedDescription
                    finish.value(error)
                }
            }
        }

        // MARK: - Dropping in

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation)
            -> NSDragOperation {
            // A drag that started in this table is a copy out, not a copy in.
            guard info.draggingSource as? NSTableView !== tableView else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            guard !urls.isEmpty else { return false }

            Task { await model.upload(urls) }
            return true
        }

        // MARK: - The menu on a right click

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }
    }
}

extension RemoteFileTable.Coordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, table.clickedRow >= 0,
              shownEntries.indices.contains(table.clickedRow)
        else { return }

        // A right click on a row that is not chosen acts on that row alone.
        let clicked = shownEntries[table.clickedRow]
        if !model.selection.contains(clicked.path) {
            model.selection = [clicked.path]
            applySelectionFromModel(to: table)
        }
        let chosen = model.selectedEntries

        if chosen.count == 1 {
            menu.addItem(withTitle: "Open", action: #selector(openChosenRow(_:)), keyEquivalent: "")
                .target = self
            menu.addItem(withTitle: "Rename…", action: #selector(renameChosen), keyEquivalent: "")
                .target = self
        }
        menu.addItem(withTitle: chosen.count == 1 ? "Copy to this Mac"
                                                  : "Copy \(chosen.count) items to this Mac",
                     action: #selector(downloadChosen), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteChosen), keyEquivalent: "")
            .target = self
    }

    @objc private func renameChosen() {
        guard let entry = model.selectedEntries.first else { return }
        model.renameRequest = entry
    }

    @objc private func downloadChosen() {
        let chosen = model.selectedEntries
        Task { await model.download(chosen) }
    }

    @objc private func deleteChosen() {
        model.deleteRequest = model.selectedEntries
    }
}
