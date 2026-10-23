import KubeKit
import SwiftUI

nonisolated struct ResourceRow: Identifiable, Sendable {
    let id: String
    let object: KubeObject
    let cells: [Cell]

    /// Tolerates stale indexes: the column set changes when switching between one and all namespaces.
    subscript(sort index: Int) -> SortKey { cells.indices.contains(index) ? cells[index].sortKey : .text("") }
}

/// State of one cluster window: which context/namespace/kind is shown, and the live object list.
@Observable
final class ClusterModel {
    var contexts: [KubeContext] = []
    var context: String?
    var namespaces: [String] = []
    /// nil means all namespaces.
    var namespace: String?
    var kind: ResourceKind = .pods
    var search = ""
    var selection = Set<String>()
    var sortOrder = [KeyPathComparator(\ResourceRow.[sort: 0])]

    private(set) var objects: [String: KubeObject] = [:]
    private(set) var isLoading = false
    private(set) var isLive = false
    var error: String?
    private(set) var now = Date()

    private(set) var client: KubeClient?
    private var app: AppModel?

    /// Tabs of the bottom panel (logs, files, YAML), like Xcode's debug area.
    private(set) var panels: [PanelTab] = []
    var activePanelID: String?
    var isPanelVisible = false
    private var watchTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?

    var columns: [Column] {
        kind.namespaced && namespace == nil ? [.namespace] + kind.columns : kind.columns
    }

    var rows: [ResourceRow] {
        let columns = columns
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return objects.values
            .filter { query.isEmpty || $0.name.lowercased().contains(query) || ($0.namespace ?? "").lowercased().contains(query) }
            .map { o in ResourceRow(id: o.id, object: o, cells: columns.map { $0.value(o, now) }) }
            .sorted(using: sortOrder + [KeyPathComparator(\ResourceRow.object.name, comparator: .localizedStandard)])
    }

    var selectedObjects: [KubeObject] { selection.compactMap { objects[$0] } }

    func start(app: AppModel, preferredContext: String?) async {
        self.app = app
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.now = Date()
            }
        }
        guard let kubectl = await app.ensureKubectl() else {
            error = app.setupError
            return
        }
        do {
            let (contexts, current) = try await KubeClient.contexts(kubectl)
            self.contexts = contexts
            let names = Set(contexts.map(\.name))
            let chosen = [preferredContext, context, current, contexts.first?.name].compactMap { $0 }.first { names.contains($0) }
            if let chosen { await switchContext(chosen, app: app) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func switchContext(_ name: String, app: AppModel) async {
        context = name
        namespace = contexts.first { $0.name == name }?.namespace
        sortOrder = [KeyPathComparator(\ResourceRow.[sort: 0])]
        namespaces = []
        guard let kubectl = await app.ensureKubectl() else { return }
        client = KubeClient(kubectl: kubectl, context: name)
        reload()
        // Listing namespaces may be forbidden by RBAC; the picker then offers just the default.
        if let list = try? await client?.namespaces(), context == name {
            namespaces = list
        }
    }

    func select(kind: ResourceKind) {
        guard kind != self.kind else { return }
        self.kind = kind
        sortOrder = [KeyPathComparator(\ResourceRow.[sort: 0])]
        reload()
    }

    func select(namespace: String?) {
        guard namespace != self.namespace else { return }
        self.namespace = namespace
        sortOrder = [KeyPathComparator(\ResourceRow.[sort: 0])]
        reload()
    }

    func reload() {
        watchTask?.cancel()
        objects = [:]
        selection = []
        error = nil
        isLive = false
        guard let client else { return }
        isLoading = true
        let kind = kind, namespace = namespace
        watchTask = Task { [weak self] in
            do {
                for try await update in client.watch(kind, namespace: namespace) {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(update)
                }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.isLoading = false
                self.isLive = false
            }
        }
    }

    private func apply(_ update: KubeClient.WatchUpdate) {
        switch update {
        case .snapshot(let list):
            objects = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            isLoading = false
            isLive = true
            selection.formIntersection(objects.keys)
        case .event(let event):
            switch event.kind {
            case .deleted:
                objects[event.object.id] = nil
                selection.remove(event.object.id)
            default:
                // The watch replays the full list on (re)connect; skip unchanged objects to avoid redraws.
                let version = event.object.raw["metadata.resourceVersion"].string
                if objects[event.object.id]?.raw["metadata.resourceVersion"].string != version {
                    objects[event.object.id] = event.object
                }
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        clockTask?.cancel()
        for tab in panels { tab.stop() }
    }

    var activePanel: PanelTab? { panels.first { $0.id == activePanelID } }

    /// Shows the request's tab, reusing an open one for the same pod/resource.
    func openPanel(_ request: PanelTab.Request) {
        if !panels.contains(where: { $0.id == request.id }) {
            guard let app else { return }
            panels.append(PanelTab(request, app: app))
        }
        activePanelID = request.id
        isPanelVisible = true
    }

    func closePanel(_ id: String) {
        guard let index = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[index].stop()
        panels.remove(at: index)
        if activePanelID == id {
            activePanelID = panels.isEmpty ? nil : panels[min(index, panels.count - 1)].id
        }
        if panels.isEmpty { isPanelVisible = false }
    }
}
