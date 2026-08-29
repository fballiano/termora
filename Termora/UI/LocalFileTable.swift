//
//  LocalFileTable.swift
//  Termora
//

import AppKit
import SwiftUI

/// The list of files on this Mac, beside the list on the far host.
///
/// This is an `NSTableView` for the same reason the remote one is: only AppKit
/// can receive a file promise. A row dragged from the remote side arrives as a
/// promise, and the copy starts when it lands here.
struct LocalFileTable: NSViewRepresentable {
    @ObservedObject var model: LocalFileModel
    /// Called when files land here, so the browser can show progress.
    let onReceive: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onReceive: onReceive) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openChosenRow(_:))

        for (title, width) in [("Name", CGFloat(220)), ("Size", 80), ("Changed", 140)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            column.width = width
            column.minWidth = title == "Name" ? 120 : 60
            table.addTableColumn(column)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.menu = context.coordinator.makeMenu()

        // A promise from the remote side, or a plain file from another app.
        var accepted = NSFilePromiseReceiver.readableDraggedTypes
            .map { NSPasteboard.PasteboardType($0) }
        accepted.append(.fileURL)
        table.registerForDraggedTypes(accepted)
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
        context.coordinator.onReceive = onReceive
        guard let table = scrollView.documentView as? NSTableView else { return }
        if context.coordinator.shownItems != model.items {
            context.coordinator.shownItems = model.items
            table.reloadData()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: LocalFileModel
        var onReceive: (Int) -> Void
        var shownItems: [LocalFileModel.Item] = []
        weak var table: NSTableView?
        private nonisolated let receiveQueue = OperationQueue()

        init(model: LocalFileModel, onReceive: @escaping (Int) -> Void) {
            self.model = model
            self.onReceive = onReceive
            super.init()
            receiveQueue.name = "com.fabrizioballiano.Termora.receiveFiles"
        }

        func numberOfRows(in tableView: NSTableView) -> Int { shownItems.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let tableColumn, shownItems.indices.contains(row) else { return nil }
            let item = shownItems[row]

            let cell = NSTableCellView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text

            var leading: CGFloat = 2
            if tableColumn.identifier.rawValue == "Name" {
                let image = NSImageView()
                image.image = NSWorkspace.shared.icon(forFile: item.url.path)
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                ])
                leading = 24
            }
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            switch tableColumn.identifier.rawValue {
            case "Name":
                text.stringValue = item.name
                cell.toolTip = item.url.path
            case "Size":
                text.stringValue = item.isDirectory
                    ? "—"
                    : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
                text.alignment = .right
                text.textColor = .secondaryLabelColor
            default:
                text.stringValue = item.modifiedAt.map {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .short
                    return formatter.string(from: $0)
                } ?? ""
                text.textColor = .secondaryLabelColor
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            model.selection = Set(table.selectedRowIndexes.compactMap {
                shownItems.indices.contains($0) ? shownItems[$0].id : nil
            })
        }

        @objc func openChosenRow(_ sender: Any?) {
            guard let table, table.clickedRow >= 0,
                  shownItems.indices.contains(table.clickedRow)
            else { return }
            model.open(shownItems[table.clickedRow])
        }

        // MARK: - Dragging out, to the far host or to Finder

        func tableView(_ tableView: NSTableView,
                       pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard shownItems.indices.contains(row) else { return nil }
            return shownItems[row].url as NSURL
        }

        // MARK: - Receiving from the far host

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation)
            -> NSDragOperation {
            guard info.draggingSource as? NSTableView !== tableView else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let destination = model.directory

            // A row dragged from the far host arrives as a promise. Asking for
            // it here is what starts the copy.
            let receivers = info.draggingPasteboard.readObjects(
                forClasses: [NSFilePromiseReceiver.self], options: nil
            ) as? [NSFilePromiseReceiver] ?? []

            if !receivers.isEmpty {
                onReceive(receivers.count)
                for receiver in receivers {
                    receiver.receivePromisedFiles(
                        atDestination: destination,
                        options: [:],
                        operationQueue: receiveQueue
                    ) { @Sendable [weak self] _, error in
                        // AppKit calls this on `receiveQueue`, never on the main
                        // thread. The closure must stay nonisolated, or the
                        // isolation check traps and the app stops.
                        let reason = error?.localizedDescription
                        Task { @MainActor in
                            if let reason {
                                self?.model.errorMessage =
                                    "Termora could not copy that file. \(reason)"
                            }
                            self?.model.reload()
                        }
                    }
                }
                return true
            }

            // A plain file from another application is copied in.
            let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            guard !urls.isEmpty else { return false }

            for url in urls where url.deletingLastPathComponent() != destination {
                try? FileManager.default.copyItem(
                    at: url, to: destination.appendingPathComponent(url.lastPathComponent)
                )
            }
            model.reload()
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

extension LocalFileTable.Coordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, table.clickedRow >= 0,
              shownItems.indices.contains(table.clickedRow)
        else { return }

        let clicked = shownItems[table.clickedRow]
        if !model.selection.contains(clicked.id) {
            model.selection = [clicked.id]
            table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        }

        menu.addItem(withTitle: "Open", action: #selector(openChosenRow(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(reveal), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(trash), keyEquivalent: "")
            .target = self
    }

    @objc private func reveal() { model.revealInFinder() }

    /// Asks the view to confirm. Nothing is moved from here.
    @objc private func trash() { model.trashRequest = model.selectedItems }
}
