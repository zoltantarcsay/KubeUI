import AppKit
import KubeKit
import SwiftUI

/// Finder-style browser of a container's filesystem, shown as a tab in the bottom panel.
struct PodFilesPanel: View {
    let model: PodFilesModel
    @Environment(AppModel.self) private var app
    @State private var pendingUpload: (urls: [URL], directory: String, conflicts: [String])?
    @State private var pendingDelete: [String] = []
    @State private var newFolder: String?
    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var goTo: String?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            controls
            Divider()
            FileOutlineView(root: model.root, children: model.children, expanded: model.expanded, selection: $model.selection, actions: actions)
                .overlay { overlay }
            ForEach(model.transfers) { TransferRow(transfer: $0, model: model) }
            PathBar(path: model.root, itemCount: model.rootFiles.count, selectionCount: model.selection.count) { model.open($0) }
        }
        .confirmationDialog(
            "Replace \(pendingUpload?.conflicts.count == 1 ? "“\(pendingUpload!.conflicts[0])”" : "\(pendingUpload?.conflicts.count ?? 0) items")?",
            isPresented: Binding(get: { pendingUpload != nil }, set: { if !$0 { pendingUpload = nil } })
        ) {
            Button("Replace", role: .destructive) {
                if let pending = pendingUpload { model.upload(pending.urls, into: pending.directory) }
            }
        } message: {
            Text("An item with the same name already exists in \(pendingUpload?.directory ?? ""). Uploading merges folders and overwrites files.")
        }
        .confirmationDialog(
            pendingDelete.count == 1 ? "Delete “\((pendingDelete[0] as NSString).lastPathComponent)”?" : "Delete \(pendingDelete.count) items?",
            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
        ) {
            Button("Delete", role: .destructive) {
                let paths = pendingDelete
                Task { await model.delete(paths) }
            }
        } message: {
            Text("Deletes from \(model.pod.pod) in \(model.pod.context). This can't be undone.")
        }
        .alert("New Folder", isPresented: Binding(get: { newFolder != nil }, set: { if !$0 { newFolder = nil } })) {
            TextField("Name", text: Binding(get: { newFolder ?? "" }, set: { newFolder = $0 }))
            Button("Create") {
                if let name = newFolder, !name.isEmpty { Task { await model.makeFolder(name, in: model.root) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename “\((renameTarget.map { ($0 as NSString).lastPathComponent }) ?? "")”", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let path = renameTarget, !renameText.isEmpty, renameText != (path as NSString).lastPathComponent {
                    let new = renameText
                    Task { await model.rename(path, to: new) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Go to Folder", isPresented: Binding(get: { goTo != nil }, set: { if !$0 { goTo = nil } })) {
            TextField("Path", text: Binding(get: { goTo ?? "" }, set: { goTo = $0 }))
            Button("Go") {
                if let path = goTo, !path.isEmpty { model.open(path.hasPrefix("/") ? path : PodFilesModel.join(model.root, path)) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't complete the operation", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
        } message: {
            Text(model.alert ?? "")
        }
    }

    private var controls: some View {
        PanelBar {
            ControlGroup {
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(model.backStack.isEmpty)
                    .keyboardShortcut("[")
                    .help("Back")
                Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(model.forwardStack.isEmpty)
                    .keyboardShortcut("]")
                    .help("Forward")
            }
            .fixedSize()
            Button { model.goUp() } label: { Label("Enclosing Folder", systemImage: "arrow.turn.left.up") }
                .disabled(model.parentOfRoot == nil)
                .keyboardShortcut(.upArrow)
                .help("Enclosing folder")
            Text(model.root).font(.callout).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
            Spacer()
            if model.pod.containers.count > 1 {
                Picker("Container", selection: Binding(
                    get: { model.container ?? "" },
                    set: { name in Task { await model.switchContainer(name, app: app) } }
                )) {
                    ForEach(model.pod.containers, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Container")
            }
            Button { newFolder = "untitled folder" } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("New folder")
            Button(action: chooseUpload) { Label("Upload", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("u")
                .help("Upload files or folders (or drag them in from Finder)")
            Button { model.download(Array(model.selection), to: downloadsFolder) } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .disabled(model.selection.isEmpty)
            .help("Download the selection to Downloads (or drag it out to Finder)")
            Button { goTo = model.root } label: { Label("Go to Folder", systemImage: "arrow.right.circle") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Go to folder")
            Button { model.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .help("Reload")
        }
    }

    private var actions: FileOutlineView.Actions {
        FileOutlineView.Actions(
            open: { model.openFile($0) },
            navigate: { model.open($0) },
            setExpanded: { model.setExpanded($0, $1) },
            drop: { urls, directory in
                let conflicts = model.conflicts(urls, in: directory)
                if conflicts.isEmpty { model.upload(urls, into: directory) } else { pendingUpload = (urls, directory, conflicts) }
                return true
            },
            promise: { path, url in try await model.fulfilPromise(remotePath: path, to: url) },
            download: { model.download($0, to: downloadsFolder) },
            delete: { pendingDelete = $0 },
            rename: { path in
                renameText = (path as NSString).lastPathComponent
                renameTarget = path
            },
            copyPath: { paths in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
            },
            newFolder: { newFolder = "untitled folder" },
            upload: chooseUpload,
            reload: { model.reload() }
        )
    }

    private var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to \(model.root)"
        guard panel.runModal() == .OK else { return }
        _ = actions.drop(panel.urls, model.root)
    }

    @ViewBuilder
    private var overlay: some View {
        if let error = model.error {
            ContentUnavailableView {
                Label("Can't Open Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Try Again") { model.reload() }
            }
            .background(.background)
        } else if model.isLoading && model.rootFiles.isEmpty {
            ProgressView().allowsHitTesting(false)
        }
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let model: PodFilesModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.title).lineLimit(1).truncationMode(.middle)
                switch transfer.state {
                case .running:
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(progressText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                case .done:
                    Text("Done").font(.caption).foregroundStyle(.secondary)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer()
            if transfer.state == .running {
                Button { model.cancel(transfer) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Cancel")
            } else {
                Button { model.dismiss(transfer) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var progressText: String {
        let done = ByteCountFormatter.string(fromByteCount: transfer.completed, countStyle: .file)
        guard let total = transfer.total else { return done }
        return "\(done) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}

/// Finder's path bar: click a component to jump there.
private struct PathBar: View {
    let path: String
    let itemCount: Int
    let selectionCount: Int
    let open: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                Button { open(component.path) } label: {
                    Label(component.name, systemImage: index == 0 ? "externaldrive" : "folder.fill")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == components.count - 1 ? .primary : .secondary)
            }
            Spacer(minLength: 12)
            Text(selectionCount > 0 ? "\(selectionCount) of \(itemCount) selected" : "\(itemCount) items")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var components: [(name: String, path: String)] {
        var result = [(name: "/", path: "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            result.append((String(part), current))
        }
        return result
    }
}
