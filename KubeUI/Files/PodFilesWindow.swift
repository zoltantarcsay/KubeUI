import AppKit
import KubeKit
import SwiftUI

struct PodFilesWindow: View {
    let pod: PodRef
    @Environment(AppModel.self) private var app
    @State private var model: PodFilesModel
    @State private var pendingUpload: (urls: [URL], conflicts: [String])?
    @State private var pendingDelete: [String] = []
    @State private var newFolder: String?
    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var goTo: String?

    init(pod: PodRef) {
        self.pod = pod
        _model = State(initialValue: PodFilesModel(pod: pod))
    }

    var body: some View {
        FileTableView(files: model.files, selection: $model.selection, actions: actions)
            .overlay { overlay }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(model.transfers) { TransferRow(transfer: $0, model: model) }
                    PathBar(path: model.path, itemCount: model.files.count, selectionCount: model.selection.count) { model.open($0) }
                }
            }
            .navigationTitle(model.path == "/" ? "/" : (model.path as NSString).lastPathComponent)
            .navigationSubtitle("\(pod.pod)\(model.container.map { " · \($0)" } ?? "") · \(pod.namespace)")
            .toolbar { toolbar }
            .task { await model.start(app: app) }
            .confirmationDialog(
                "Replace \(pendingUpload?.conflicts.count == 1 ? "“\(pendingUpload!.conflicts[0])”" : "\(pendingUpload?.conflicts.count ?? 0) items")?",
                isPresented: Binding(get: { pendingUpload != nil }, set: { if !$0 { pendingUpload = nil } })
            ) {
                Button("Replace", role: .destructive) {
                    if let urls = pendingUpload?.urls { model.upload(urls) }
                }
            } message: {
                Text("An item with the same name already exists in \(model.path). Uploading merges folders and overwrites files.")
            }
            .confirmationDialog(
                pendingDelete.count == 1 ? "Delete “\(pendingDelete.first ?? "")”?" : "Delete \(pendingDelete.count) items?",
                isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
            ) {
                Button("Delete", role: .destructive) {
                    let names = pendingDelete
                    Task { await model.delete(names) }
                }
            } message: {
                Text("Deletes from \(pod.pod) in \(pod.context). This can't be undone.")
            }
            .alert("New Folder", isPresented: Binding(get: { newFolder != nil }, set: { if !$0 { newFolder = nil } })) {
                TextField("Name", text: Binding(get: { newFolder ?? "" }, set: { newFolder = $0 }))
                Button("Create") {
                    if let name = newFolder, !name.isEmpty { Task { await model.makeFolder(name) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename “\(renameTarget ?? "")”", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let old = renameTarget, !renameText.isEmpty, renameText != old {
                        let new = renameText
                        Task { await model.rename(old, to: new) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Go to Folder", isPresented: Binding(get: { goTo != nil }, set: { if !$0 { goTo = nil } })) {
                TextField("Path", text: Binding(get: { goTo ?? "" }, set: { goTo = $0 }))
                Button("Go") {
                    if let path = goTo, !path.isEmpty { model.open(path.hasPrefix("/") ? path : model.childPath(path)) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't complete the operation", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            } message: {
                Text(model.alert ?? "")
            }
    }

    private var actions: FileTableView.Actions {
        FileTableView.Actions(
            open: { file in
                if file.isNavigable { model.open(model.childPath(file.name)) } else { model.openFile(file.name) }
            },
            drop: { urls, folder in
                if let folder {
                    model.upload(urls, into: model.childPath(folder))
                    return true
                }
                let existing = Set(model.files.map(\.name))
                let conflicts = urls.map(\.lastPathComponent).filter(existing.contains)
                if conflicts.isEmpty { model.upload(urls) } else { pendingUpload = (urls, conflicts) }
                return true
            },
            promise: { [path = model.path] name, url in
                try await model.fulfilPromise(remotePath: path == "/" ? "/" + name : path + "/" + name, to: url)
            },
            download: { names in model.download(names, to: downloadsFolder) },
            delete: { pendingDelete = $0 },
            rename: { name in
                renameText = name
                renameTarget = name
            },
            copyPath: { names in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(names.map(model.childPath).joined(separator: "\n"), forType: .string)
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
        panel.message = "Choose files or folders to upload to \(model.path)"
        guard panel.runModal() == .OK else { return }
        _ = actions.drop(panel.urls, nil)
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
        } else if model.isLoading && model.files.isEmpty {
            ProgressView().allowsHitTesting(false)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(model.backStack.isEmpty)
                .keyboardShortcut("[")
                .help("Back")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(model.forwardStack.isEmpty)
                .keyboardShortcut("]")
                .help("Forward")
            Button { model.goUp() } label: { Label("Enclosing Folder", systemImage: "arrow.turn.left.up") }
                .disabled(model.parentPath == nil)
                .keyboardShortcut(.upArrow)
                .help("Enclosing folder")
        }
        if pod.containers.count > 1 {
            ToolbarItem {
                Picker("Container", selection: Binding(
                    get: { model.container ?? "" },
                    set: { name in Task { await model.switchContainer(name, app: app) } }
                )) {
                    ForEach(pod.containers, id: \.self) { Text($0).tag($0) }
                }
                .help("Container")
            }
        }
        ToolbarItemGroup {
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
            Button { goTo = model.path } label: { Label("Go to Folder", systemImage: "arrow.right.circle") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Go to folder")
            Button { model.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
                .help("Reload")
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
