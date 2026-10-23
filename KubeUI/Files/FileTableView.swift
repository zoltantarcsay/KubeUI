import AppKit
import KubeKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style list of a container directory, in AppKit because SwiftUI's Table can't target
/// drops onto a specific row or vend file promises for dragging out to Finder.
struct FileTableView: NSViewRepresentable {
    struct Actions {
        var open: (RemoteFile) -> Void
        /// Dropped local files; the folder name is set when dropped onto a folder row.
        var drop: ([URL], String?) -> Bool
        /// Fulfils a drag-out to Finder: (file name, destination URL).
        var promise: (String, URL) async throws -> Void
        var download: ([String]) -> Void
        var delete: ([String]) -> Void
        var rename: (String) -> Void
        var copyPath: ([String]) -> Void
        var newFolder: () -> Void
        var upload: () -> Void
        var reload: () -> Void
    }

    let files: [RemoteFile]
    @Binding var selection: Set<String>
    let actions: Actions

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileNSTableView()
        table.coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 22
        table.autosaveName = "KubeUIFileTable"

        for spec in Coordinator.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 50
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            if spec.alignRight { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.autosaveTableColumns = true
        if table.sortDescriptors.isEmpty { table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)] }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSFilePromiseProviderDelegate {
        struct ColumnSpec {
            let id: String, title: String, width: CGFloat, alignRight: Bool
        }

        static let columns = [
            ColumnSpec(id: "name", title: "Name", width: 280, alignRight: false),
            ColumnSpec(id: "date", title: "Date Modified", width: 170, alignRight: false),
            ColumnSpec(id: "size", title: "Size", width: 80, alignRight: true),
            ColumnSpec(id: "kind", title: "Kind", width: 130, alignRight: false),
            ColumnSpec(id: "perms", title: "Permissions", width: 100, alignRight: false),
            ColumnSpec(id: "owner", title: "Owner", width: 110, alignRight: false),
        ]

        var parent: FileTableView
        weak var table: NSTableView?
        private(set) var rows: [RemoteFile] = []
        private var updatingSelection = false
        private nonisolated let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.qualityOfService = .userInitiated
            return q
        }()

        init(_ parent: FileTableView) {
            self.parent = parent
        }

        func update(_ parent: FileTableView) {
            let filesChanged = parent.files != self.parent.files || rows.count != parent.files.count
            self.parent = parent
            guard let table else { return }
            if filesChanged {
                rows = sorted(parent.files, by: table.sortDescriptors)
                table.reloadData()
            }
            let wanted = IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].name) })
            if wanted != table.selectedRowIndexes {
                updatingSelection = true
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                updatingSelection = false
            }
        }

        private func sorted(_ files: [RemoteFile], by descriptors: [NSSortDescriptor]) -> [RemoteFile] {
            let descriptor = descriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
            let ascending = descriptor.ascending
            return files.sorted { a, b in
                let result: ComparisonResult = switch descriptor.key {
                case "date": compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
                case "size": compare(a.isDirectory ? -1 : a.size ?? 0, b.isDirectory ? -1 : b.size ?? 0)
                case "kind": FileTableView.kindName(a).localizedStandardCompare(FileTableView.kindName(b))
                case "perms": (a.permissions ?? "").compare(b.permissions ?? "")
                case "owner": (a.owner ?? "").localizedStandardCompare(b.owner ?? "")
                default: .orderedSame
                }
                let resolved = result == .orderedSame ? a.name.localizedStandardCompare(b.name) : result
                return ascending ? resolved == .orderedAscending : resolved == .orderedDescending
            }
        }

        private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }

        // MARK: Data source & delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            rows = sorted(parent.files, by: tableView.sortDescriptors)
            tableView.reloadData()
            update(parent)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, rows.indices.contains(row) else { return nil }
            let file = rows[row]
            let id = column.identifier
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.textField?.stringValue = file.name
                cell.imageView?.image = FileTableView.icon(for: file)
            case "date":
                cell.textField?.stringValue = file.modified.map { FileTableView.dateFormatter.string(from: $0) } ?? "--"
            case "size":
                cell.textField?.stringValue = file.isNavigable || file.kind == .symlink || file.size == nil ? "--" : ByteCountFormatter.string(fromByteCount: file.size!, countStyle: .file)
            case "kind":
                cell.textField?.stringValue = FileTableView.kindName(file)
            case "perms":
                cell.textField?.stringValue = file.permissions ?? ""
            case "owner":
                cell.textField?.stringValue = [file.owner, file.group].compactMap { $0 }.joined(separator: ":")
            default:
                break
            }
            let secondary = id.rawValue != "name"
            cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            text.font = id.rawValue == "perms" ? .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
            if id.rawValue == "size" { text.alignment = .right }
            cell.addSubview(text)
            cell.textField = text
            if id.rawValue == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let table else { return }
            let names = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].name : nil })
            if names != parent.selection { parent.selection = names }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            parent.actions.open(rows[row])
        }

        func openSelection() {
            guard let table, let row = table.selectedRowIndexes.first, rows.indices.contains(row) else { return }
            parent.actions.open(rows[row])
        }

        /// Finder semantics: right-clicking inside the selection acts on all of it.
        func targetNames() -> [String] {
            guard let table else { return [] }
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked), rows.indices.contains(clicked) {
                return [rows[clicked].name]
            }
            return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].name : nil }
        }

        // MARK: Drop (upload)

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
            if op == .on, rows.indices.contains(row), rows[row].isNavigable { return .copy }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let folder = dropOperation == .on && rows.indices.contains(row) && rows[row].isNavigable ? rows[row].name : nil
            return parent.actions.drop(urls, folder)
        }

        // MARK: Drag out (download via file promise)

        final class PromiseInfo: @unchecked Sendable {
            let name: String
            let fulfil: (String, URL) async throws -> Void
            init(name: String, fulfil: @escaping (String, URL) async throws -> Void) {
                self.name = name
                self.fulfil = fulfil
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard rows.indices.contains(row) else { return nil }
            let file = rows[row]
            let type: UTType = file.isNavigable ? .folder : (UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = PromiseInfo(name: file.name, fulfil: parent.actions.promise)
            return provider
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (provider.userInfo as? PromiseInfo)?.name ?? "download"
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            guard let info = provider.userInfo as? PromiseInfo else { return completionHandler(CocoaError(.fileWriteUnknown)) }
            nonisolated(unsafe) let completion = completionHandler
            Task { @MainActor in
                do {
                    try await info.fulfil(info.name, url)
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }

        nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
            promiseQueue
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let names = targetNames()
            func add(_ title: String, _ action: @escaping () -> Void) {
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
                let target = MenuAction(action)
                item.target = target
                item.representedObject = target
                menu.addItem(item)
            }
            if names.isEmpty {
                add("New Folder…") { self.parent.actions.newFolder() }
                add("Upload…") { self.parent.actions.upload() }
                menu.addItem(.separator())
                add("Reload") { self.parent.actions.reload() }
                return
            }
            if names.count == 1, let file = rows.first(where: { $0.name == names[0] }) {
                add("Open") { self.parent.actions.open(file) }
            }
            add(names.count == 1 ? "Download to Downloads" : "Download \(names.count) Items to Downloads") { self.parent.actions.download(names) }
            if names.count == 1 {
                add("Rename…") { self.parent.actions.rename(names[0]) }
            }
            add(names.count == 1 ? "Copy Path" : "Copy Paths") { self.parent.actions.copyPath(names) }
            menu.addItem(.separator())
            add("Delete…") { self.parent.actions.delete(names) }
        }
    }

    static func icon(for file: RemoteFile) -> NSImage {
        let type: UTType = file.isNavigable ? .folder : (file.kind == .symlink ? .symbolicLink : (UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data))
        return NSWorkspace.shared.icon(for: type)
    }

    static func kindName(_ file: RemoteFile) -> String {
        switch file.kind {
        case .directory: return "Folder"
        case .symlink: return file.isNavigable ? "Folder Link" : "Symbolic Link"
        case .other(let raw): return raw.capitalized
        case .file:
            let ext = (file.name as NSString).pathExtension
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else { return "Document" }
            return type.localizedDescription ?? "Document"
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}

private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// Finder keyboard shortcuts: ⌘↓ opens, ⌘⌫ deletes.
final class FileNSTableView: NSTableView {
    weak var coordinator: FileTableView.Coordinator?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch Int(event.keyCode) {
            case 125: // down arrow
                coordinator?.openSelection()
                return
            case 51: // delete
                if let names = coordinator?.targetNames(), !names.isEmpty {
                    coordinator?.parent.actions.delete(names)
                }
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}
