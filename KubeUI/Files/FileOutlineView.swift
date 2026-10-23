import AppKit
import KubeKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder list view of a container directory with expandable folders. AppKit, because SwiftUI
/// can't target drops onto a specific row or vend file promises for dragging out to Finder.
struct FileOutlineView: NSViewRepresentable {
    struct Actions {
        var open: (String) -> Void
        /// Shows a folder as the new root (⌘↓ in Finder).
        var navigate: (String) -> Void
        var setExpanded: (String, Bool) -> Void
        /// Dropped local files and the folder they were dropped into.
        var drop: ([URL], String) -> Bool
        /// Fulfils a drag-out to Finder: (remote path, destination URL).
        var promise: (String, URL) async throws -> Void
        var download: ([String]) -> Void
        var delete: ([String]) -> Void
        var rename: (String) -> Void
        var copyPath: ([String]) -> Void
        var newFolder: () -> Void
        var upload: () -> Void
        var reload: () -> Void
    }

    let root: String
    let children: [String: [RemoteFile]]
    /// Restored when the view is rebuilt, e.g. after switching panel tabs.
    let expanded: Set<String>
    @Binding var selection: Set<String>
    let actions: Actions

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FileNSOutlineView()
        outline.coordinator = context.coordinator
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.rowHeight = 22
        outline.autosaveName = "KubeUIFileOutline"

        for spec in Coordinator.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 50
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            if spec.alignRight { column.headerCell.alignment = .right }
            outline.addTableColumn(column)
            if spec.id == "name" { outline.outlineTableColumn = column }
        }
        outline.autosaveTableColumns = true
        if outline.sortDescriptors.isEmpty { outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)] }

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask([], forLocal: true)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    /// Reference identity per path, so NSOutlineView keeps expansion state across reloads.
    final class FileNode: NSObject {
        let path: String
        var file: RemoteFile
        init(path: String, file: RemoteFile) {
            self.path = path
            self.file = file
        }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSFilePromiseProviderDelegate {
        struct ColumnSpec {
            let id: String, title: String, width: CGFloat, alignRight: Bool
        }

        static let columns = [
            ColumnSpec(id: "name", title: "Name", width: 300, alignRight: false),
            ColumnSpec(id: "date", title: "Date Modified", width: 170, alignRight: false),
            ColumnSpec(id: "size", title: "Size", width: 80, alignRight: true),
            ColumnSpec(id: "kind", title: "Kind", width: 130, alignRight: false),
            ColumnSpec(id: "perms", title: "Permissions", width: 100, alignRight: false),
            ColumnSpec(id: "owner", title: "Owner", width: 110, alignRight: false),
        ]

        var parent: FileOutlineView
        weak var outline: NSOutlineView?
        private var root = ""
        private var listings: [String: [RemoteFile]] = [:]
        private var nodes: [String: FileNode] = [:]
        /// Sorted child nodes per directory path.
        private var shown: [String: [FileNode]] = [:]
        private var syncing = false
        private nonisolated let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.qualityOfService = .userInitiated
            return q
        }()

        init(_ parent: FileOutlineView) {
            self.parent = parent
        }

        func update(_ parent: FileOutlineView) {
            self.parent = parent
            guard let outline else { return }
            syncing = true
            defer { syncing = false }
            if parent.root != root {
                root = parent.root
                listings = parent.children
                nodes = [:]
                shown = [:]
                for (dir, files) in listings { shown[dir] = makeNodes(dir, files) }
                outline.reloadData()
                for path in parent.expanded.sorted(by: { $0.count < $1.count }) {
                    if let node = nodes[path] { outline.expandItem(node) }
                }
            } else {
                // Reload only the folders whose listing changed, keeping scroll position and expansion.
                let changed = parent.children.filter { listings[$0.key] != $0.value }
                listings = parent.children
                for (dir, files) in changed.sorted(by: { $0.key.count < $1.key.count }) {
                    shown[dir] = makeNodes(dir, files)
                    if dir == root {
                        outline.reloadItem(nil, reloadChildren: true)
                    } else if let node = nodes[dir], outline.row(forItem: node) >= 0 {
                        outline.reloadItem(node, reloadChildren: true)
                    }
                }
            }
            for path in parent.expanded.sorted(by: { $0.count < $1.count }) {
                if let node = nodes[path], outline.row(forItem: node) >= 0, !outline.isItemExpanded(node) { outline.expandItem(node) }
            }
            let wanted = IndexSet(parent.selection.compactMap { nodes[$0].map { outline.row(forItem: $0) } }.filter { $0 >= 0 })
            if wanted != outline.selectedRowIndexes {
                outline.selectRowIndexes(wanted, byExtendingSelection: false)
            }
        }

        private func makeNodes(_ dir: String, _ files: [RemoteFile]) -> [FileNode] {
            sorted(files).map { file in
                let path = PodFilesModel.join(dir, file.name)
                if let node = nodes[path] {
                    node.file = file
                    return node
                }
                let node = FileNode(path: path, file: file)
                nodes[path] = node
                return node
            }
        }

        private func sorted(_ files: [RemoteFile]) -> [RemoteFile] {
            let descriptor = outline?.sortDescriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
            let ascending = descriptor.ascending
            return files.sorted { a, b in
                let result: ComparisonResult = switch descriptor.key {
                case "date": compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
                case "size": compare(a.isDirectory ? -1 : a.size ?? 0, b.isDirectory ? -1 : b.size ?? 0)
                case "kind": FileOutlineView.kindName(a).localizedStandardCompare(FileOutlineView.kindName(b))
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

        private func node(_ item: Any?) -> FileNode? { item as? FileNode }

        // MARK: Data source & delegate

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            shown[node(item)?.path ?? root]?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            shown[node(item)?.path ?? root]![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            node(item)?.file.isNavigable ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            syncing = true
            for (dir, files) in listings { shown[dir] = makeNodes(dir, files) }
            outlineView.reloadData()
            syncing = false
            update(parent)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !syncing, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            parent.actions.setExpanded(node.path, true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !syncing, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            parent.actions.setExpanded(node.path, false)
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let column = tableColumn, let file = node(item)?.file else { return nil }
            let id = column.identifier
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.textField?.stringValue = file.name
                cell.imageView?.image = FileOutlineView.icon(for: file)
            case "date":
                cell.textField?.stringValue = file.modified.map { FileOutlineView.dateFormatter.string(from: $0) } ?? "--"
            case "size":
                cell.textField?.stringValue = file.isNavigable || file.kind == .symlink || file.size == nil
                    ? "--" : ByteCountFormatter.string(fromByteCount: file.size!, countStyle: .file)
            case "kind":
                cell.textField?.stringValue = FileOutlineView.kindName(file)
            case "perms":
                cell.textField?.stringValue = file.permissions ?? ""
            case "owner":
                cell.textField?.stringValue = [file.owner, file.group].compactMap { $0 }.joined(separator: ":")
            default:
                break
            }
            cell.textField?.textColor = id.rawValue == "name" ? .labelColor : .secondaryLabelColor
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

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline else { return }
            let paths = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.path })
            if paths != parent.selection { parent.selection = paths }
        }

        /// Finder list view: double-clicking a folder expands it in place, files open.
        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard let node = sender.item(atRow: sender.clickedRow) as? FileNode else { return }
            if node.file.isNavigable {
                sender.isItemExpanded(node) ? sender.collapseItem(node) : sender.expandItem(node)
            } else {
                parent.actions.open(node.path)
            }
        }

        func openSelection() {
            guard let outline, let node = outline.item(atRow: outline.selectedRow) as? FileNode else { return }
            node.file.isNavigable ? parent.actions.navigate(node.path) : parent.actions.open(node.path)
        }

        /// Finder semantics: right-clicking inside the selection acts on all of it.
        func targetPaths() -> [String] {
            guard let outline else { return [] }
            let clicked = outline.clickedRow
            if clicked >= 0, !outline.selectedRowIndexes.contains(clicked), let node = outline.item(atRow: clicked) as? FileNode {
                return [node.path]
            }
            return outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.path }
        }

        // MARK: Drop (upload)

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
            // Always drop *into* a folder: the one under the pointer, a file's folder, or the root.
            if let target = node(item), target.file.isNavigable {
                outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else if let file = node(item) {
                let parentPath = PodFilesModel.parent(of: file.path)
                outlineView.setDropItem(parentPath == root ? nil : nodes[parentPath], dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else {
                outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            return .copy
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            return parent.actions.drop(urls, node(item)?.path ?? root)
        }

        // MARK: Drag out (download via file promise)

        final class PromiseInfo: @unchecked Sendable {
            let path: String
            let fulfil: (String, URL) async throws -> Void
            init(path: String, fulfil: @escaping (String, URL) async throws -> Void) {
                self.path = path
                self.fulfil = fulfil
            }
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let node = node(item) else { return nil }
            let type: UTType = node.file.isNavigable ? .folder : (UTType(filenameExtension: (node.file.name as NSString).pathExtension) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = PromiseInfo(path: node.path, fulfil: parent.actions.promise)
            return provider
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            ((provider.userInfo as? PromiseInfo)?.path as NSString?)?.lastPathComponent ?? "download"
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            guard let info = provider.userInfo as? PromiseInfo else { return completionHandler(CocoaError(.fileWriteUnknown)) }
            nonisolated(unsafe) let completion = completionHandler
            Task { @MainActor in
                do {
                    try await info.fulfil(info.path, url)
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
            let paths = targetPaths()
            func add(_ title: String, _ action: @escaping () -> Void) {
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
                let target = MenuAction(action)
                item.target = target
                item.representedObject = target
                menu.addItem(item)
            }
            if paths.isEmpty {
                add("New Folder…") { self.parent.actions.newFolder() }
                add("Upload…") { self.parent.actions.upload() }
                menu.addItem(.separator())
                add("Reload") { self.parent.actions.reload() }
                return
            }
            if paths.count == 1, let node = nodes[paths[0]] {
                if node.file.isNavigable {
                    add("Open as Root") { self.parent.actions.navigate(node.path) }
                } else {
                    add("Open") { self.parent.actions.open(node.path) }
                }
            }
            add(paths.count == 1 ? "Download to Downloads" : "Download \(paths.count) Items to Downloads") { self.parent.actions.download(paths) }
            if paths.count == 1 {
                add("Rename…") { self.parent.actions.rename(paths[0]) }
            }
            add(paths.count == 1 ? "Copy Path" : "Copy Paths") { self.parent.actions.copyPath(paths) }
            menu.addItem(.separator())
            add("Delete…") { self.parent.actions.delete(paths) }
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

/// Finder keyboard shortcuts: ⌘↓ opens (folders become the root), ⌘⌫ deletes.
final class FileNSOutlineView: NSOutlineView {
    weak var coordinator: FileOutlineView.Coordinator?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            switch Int(event.keyCode) {
            case 125: // down arrow
                coordinator?.openSelection()
                return
            case 51: // delete
                if let paths = coordinator?.targetPaths(), !paths.isEmpty {
                    coordinator?.parent.actions.delete(paths)
                }
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}
