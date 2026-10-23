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

/// One Finder-like window onto a container's filesystem.
@Observable
final class PodFilesModel {
    let pod: PodRef
    var container: String?
    private(set) var path = "/"
    private(set) var files: [RemoteFile] = []
    private(set) var isLoading = false
    /// Listing failure, shown in place of the files.
    var error: String?
    /// Failed file operation, shown as an alert.
    var alert: String?
    var selection = Set<String>()
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    private(set) var transfers: [Transfer] = []
    private var fs: PodFileSystem?
    private var loadTask: Task<Void, Never>?

    init(pod: PodRef) {
        self.pod = pod
        container = pod.containers.first
    }

    var title: String { pod.pod + (pod.containers.count > 1 ? " — \(container ?? "")" : "") }

    func start(app: AppModel) async {
        guard let kubectl = await app.ensureKubectl() else {
            error = app.setupError
            return
        }
        fs = PodFileSystem(kubectl: kubectl, pod: pod, container: container)
        let start = (try? await fs?.workingDirectory()) ?? "/"
        backStack = []
        forwardStack = []
        load(start)
    }

    func switchContainer(_ name: String, app: AppModel) async {
        guard name != container else { return }
        container = name
        await start(app: app)
    }

    func childPath(_ name: String) -> String {
        path == "/" ? "/" + name : path + "/" + name
    }

    var parentPath: String? {
        path == "/" ? nil : ((path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent)
    }

    func open(_ newPath: String) {
        guard newPath != path else { return reload() }
        backStack.append(path)
        forwardStack = []
        load(newPath)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        load(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        load(next)
    }

    func goUp() {
        if let parentPath { open(parentPath) }
    }

    func reload() { load(path) }

    private func load(_ target: String) {
        guard let fs else { return }
        let normalized = target.isEmpty ? "/" : (target.count > 1 && target.hasSuffix("/") ? String(target.dropLast()) : target)
        loadTask?.cancel()
        isLoading = true
        error = nil
        loadTask = Task {
            do {
                let listing = try await fs.list(normalized)
                guard !Task.isCancelled else { return }
                if normalized != path { selection = [] }
                path = normalized
                files = listing
                selection.formIntersection(listing.map(\.name))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                if normalized != path { files = [] }
                path = normalized
            }
            isLoading = false
        }
    }

    // MARK: - Transfers

    /// `directory` nil means the folder being shown.
    func upload(_ urls: [URL], into directory: String? = nil) {
        guard let fs, !urls.isEmpty else { return }
        let target = directory ?? path
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        let transfer = Transfer(direction: .upload, title: "Uploading \(title) to \(target)")
        transfers.append(transfer)
        transfer.task = Task {
            do {
                try await fs.upload(urls, to: target) { sent, total in
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
            if target == path { reload() }
        }
    }

    func download(_ names: [String], to folder: URL, reveal: Bool = true) {
        guard let fs else { return }
        for name in names {
            let remote = childPath(name)
            let size = files.first { $0.name == name && !$0.isDirectory }?.size
            let transfer = Transfer(direction: .download, title: "Downloading \(name)", total: size)
            transfers.append(transfer)
            transfer.task = Task {
                do {
                    let local = try await fs.download(remote, to: folder.appendingPathComponent(name)) { received in
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

    var fileSystem: PodFileSystem? { fs }

    /// Downloads to a temporary folder and opens with the default app, like double-clicking in Finder.
    func openFile(_ name: String) {
        guard let fs else { return }
        let remote = childPath(name)
        let transfer = Transfer(direction: .download, title: "Opening \(name)", total: files.first { $0.name == name }?.size)
        transfers.append(transfer)
        transfer.task = Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KubeUI/\(UUID().uuidString.prefix(8))")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let local = try await fs.download(remote, to: folder.appendingPathComponent(name)) { received in
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

    /// Fulfils a Finder drag-out file promise. `remotePath` is captured when the drag starts.
    func fulfilPromise(remotePath: String, to url: URL) async throws {
        guard let fs else { throw CocoaError(.fileWriteUnknown) }
        let name = (remotePath as NSString).lastPathComponent
        let transfer = Transfer(direction: .download, title: "Copying \(name) to \(url.deletingLastPathComponent().lastPathComponent)",
                                total: files.first { $0.name == name && !$0.isDirectory }?.size)
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

    private func finish(_ transfer: Transfer) {
        guard transfer.state == .done else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            dismiss(transfer)
        }
    }

    // MARK: - File operations

    func makeFolder(_ name: String) async {
        await run { try await $0.makeDirectory(self.childPath(name)) }
    }

    func delete(_ names: [String]) async {
        await run { fs in try await fs.remove(names.map(self.childPath)) }
    }

    func rename(_ name: String, to newName: String) async {
        await run { try await $0.rename(self.childPath(name), to: self.childPath(newName)) }
    }

    private func run(_ operation: (PodFileSystem) async throws -> Void) async {
        guard let fs else { return }
        do {
            try await operation(fs)
        } catch {
            alert = error.localizedDescription
        }
        reload()
    }
}
