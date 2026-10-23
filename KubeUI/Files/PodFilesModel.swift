import AppKit
import KubeKit
import SwiftUI

@Observable
final class Transfer: Identifiable {
    enum Direction { case upload, download }
    enum State: Equatable { case running, done, failed(String), cancelled }

    let id = UUID()
    let direction: Direction
    let title: String
    var completed: Int64 = 0
    var total: Int64?
    var state: State = .running
    var task: Task<Void, Never>?

    init(direction: Direction, title: String, total: Int64? = nil) {
        self.direction = direction
        self.title = title
        self.total = total
    }

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}

/// A Finder-like list view onto a container's filesystem: a root folder whose subfolders
/// expand in place. Everything is addressed by absolute path.
@Observable
final class PodFilesModel {
    let pod: PodRef
    var container: String?
    private(set) var root = "/"
    /// Listings by directory path; a folder's children are loaded when it is first expanded.
    private(set) var children: [String: [RemoteFile]] = [:]
    private(set) var loading = Set<String>()
    /// Folders the outline currently shows expanded.
    private(set) var expanded = Set<String>()
    /// Listing failure of the root, shown in place of the files.
    var error: String?
    /// Failed file operation, shown as an alert.
    var alert: String?
    var selection = Set<String>()
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    private(set) var transfers: [Transfer] = []
    private var fs: PodFileSystem?

    init(pod: PodRef) {
        self.pod = pod
        container = pod.containers.first
    }

    var isLoading: Bool { loading.contains(root) }
    var rootFiles: [RemoteFile] { children[root] ?? [] }

    func start(app: AppModel) async {
        guard let kubectl = await app.ensureKubectl() else {
            error = app.setupError
            return
        }
        fs = PodFileSystem(kubectl: kubectl, pod: pod, container: container)
        let start = (try? await fs?.workingDirectory()) ?? "/"
        backStack = []
        forwardStack = []
        setRoot(start)
    }

    func switchContainer(_ name: String, app: AppModel) async {
        guard name != container else { return }
        container = name
        await start(app: app)
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    func file(at path: String) -> RemoteFile? {
        let name = (path as NSString).lastPathComponent
        return children[Self.parent(of: path)]?.first { $0.name == name }
    }

    var parentOfRoot: String? { root == "/" ? nil : Self.parent(of: root) }

    // MARK: - Navigation

    func open(_ path: String) {
        guard normalize(path) != root else { return reload() }
        backStack.append(root)
        forwardStack = []
        setRoot(path)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(root)
        setRoot(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(root)
        setRoot(next)
    }

    func goUp() {
        if let parentOfRoot { open(parentOfRoot) }
    }

    private func normalize(_ path: String) -> String {
        path.isEmpty ? "/" : (path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path)
    }

    private func setRoot(_ path: String) {
        root = normalize(path)
        children = [:]
        expanded = []
        selection = []
        load(root)
    }

    /// Refreshes the root and every expanded folder.
    func reload() {
        load(root)
        for dir in expanded { load(dir) }
    }

    func setExpanded(_ path: String, _ isExpanded: Bool) {
        if isExpanded {
            expanded.insert(path)
            if children[path] == nil { load(path) }
        } else {
            expanded = expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
        }
    }

    func load(_ dir: String) {
        guard let fs, !loading.contains(dir) else { return }
        loading.insert(dir)
        if dir == root { error = nil }
        let rootAtStart = root
        Task {
            defer { loading.remove(dir) }
            do {
                let listing = try await fs.list(dir)
                guard root == rootAtStart else { return }
                children[dir] = listing
                let names = Set(listing.map { Self.join(dir, $0.name) })
                selection = selection.filter { Self.parent(of: $0) != dir || names.contains($0) }
            } catch {
                guard root == rootAtStart else { return }
                if dir == root {
                    self.error = error.localizedDescription
                    children[dir] = []
                } else {
                    alert = error.localizedDescription
                    children[dir] = []
                }
            }
        }
    }

    // MARK: - Transfers

    func upload(_ urls: [URL], into directory: String) {
        guard let fs, !urls.isEmpty else { return }
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        let transfer = Transfer(direction: .upload, title: "Uploading \(title) to \(directory)")
        transfers.append(transfer)
        transfer.task = Task {
            do {
                try await fs.upload(urls, to: directory) { sent, total in
                    Task { @MainActor in
                        transfer.completed = sent
                        transfer.total = total
                    }
                }
                transfer.state = .done
            } catch {
                transfer.state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            finish(transfer)
            if directory == root || expanded.contains(directory) { load(directory) }
        }
    }

    /// Names in `directory` that an upload of `urls` would overwrite, when its listing is known.
    func conflicts(_ urls: [URL], in directory: String) -> [String] {
        let existing = Set((children[directory] ?? []).map(\.name))
        return urls.map(\.lastPathComponent).filter(existing.contains)
    }

    func download(_ paths: [String], to folder: URL, reveal: Bool = true) {
        guard let fs else { return }
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let size = file(at: path).flatMap { $0.isDirectory ? nil : $0.size }
            let transfer = Transfer(direction: .download, title: "Downloading \(name)", total: size)
            transfers.append(transfer)
            transfer.task = Task {
                do {
                    let local = try await fs.download(path, to: folder.appendingPathComponent(name)) { received in
                        Task { @MainActor in transfer.completed = received }
                    }
                    transfer.state = .done
                    if reveal { NSWorkspace.shared.activateFileViewerSelecting([local]) }
                } catch {
                    transfer.state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
                }
                finish(transfer)
            }
        }
    }

    /// Downloads to a temporary folder and opens with the default app, like double-clicking in Finder.
    func openFile(_ path: String) {
        guard let fs else { return }
        let name = (path as NSString).lastPathComponent
        let transfer = Transfer(direction: .download, title: "Opening \(name)", total: file(at: path)?.size)
        transfers.append(transfer)
        transfer.task = Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KubeUI/\(UUID().uuidString.prefix(8))")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let local = try await fs.download(path, to: folder.appendingPathComponent(name)) { received in
                    Task { @MainActor in transfer.completed = received }
                }
                transfer.state = .done
                NSWorkspace.shared.open(local)
            } catch {
                transfer.state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            finish(transfer)
        }
    }

    /// Fulfils a Finder drag-out file promise.
    func fulfilPromise(remotePath: String, to url: URL) async throws {
        guard let fs else { throw CocoaError(.fileWriteUnknown) }
        let name = (remotePath as NSString).lastPathComponent
        let transfer = Transfer(direction: .download, title: "Copying \(name) to \(url.deletingLastPathComponent().lastPathComponent)",
                                total: file(at: remotePath).flatMap { $0.isDirectory ? nil : $0.size })
        transfers.append(transfer)
        defer { finish(transfer) }
        do {
            _ = try await fs.download(remotePath, to: url) { received in
                Task { @MainActor in transfer.completed = received }
            }
            transfer.state = .done
        } catch {
            transfer.state = .failed(error.localizedDescription)
            throw error
        }
    }

    func cancel(_ transfer: Transfer) {
        transfer.task?.cancel()
    }

    func dismiss(_ transfer: Transfer) {
        transfers.removeAll { $0.id == transfer.id }
    }

    /// Stops running transfers, e.g. when the panel is closed.
    func stop() {
        for transfer in transfers { transfer.task?.cancel() }
    }

    private func finish(_ transfer: Transfer) {
        guard transfer.state == .done else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            dismiss(transfer)
        }
    }

    // MARK: - File operations

    func makeFolder(_ name: String, in directory: String) async {
        await run(reloading: [directory]) { try await $0.makeDirectory(Self.join(directory, name)) }
    }

    func delete(_ paths: [String]) async {
        await run(reloading: Set(paths.map(Self.parent))) { try await $0.remove(paths) }
    }

    func rename(_ path: String, to newName: String) async {
        let dir = Self.parent(of: path)
        await run(reloading: [dir]) { try await $0.rename(path, to: Self.join(dir, newName)) }
    }

    private func run(reloading dirs: Set<String>, _ operation: (PodFileSystem) async throws -> Void) async {
        guard let fs else { return }
        do {
            try await operation(fs)
        } catch {
            alert = error.localizedDescription
        }
        for dir in dirs where dir == root || expanded.contains(dir) { load(dir) }
    }
}
