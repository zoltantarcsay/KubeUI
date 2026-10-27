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
    /// Side-by-side splits of the panel, each showing its own tabs.
    private(set) var panelSplits: [PanelSplit] = []
    /// The last selected tab; its split is where new tabs open.
    private(set) var activePanelID: String?
    var isPanelVisible = false

    /// Whether this cluster serves Argo CD's API; adds the Argo CD sidebar section.
    private(set) var argoAvailable = false
    /// The Argo CD application drilled into from the Applications list.
    private(set) var focusedApp: ArgoAppModel?
    private var watchTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?

    var columns: [Column] {
        kind.namespaced && listNamespace == nil && kind.section != .argocd ? [.namespace] + kind.columns : kind.columns
    }

    /// Argo CD objects live in Argo's own namespace, so they're always listed cluster-wide.
    var listNamespace: String? { kind.section == .argocd ? nil : namespace }

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
        closeApplication()
        argoAvailable = false
        if kind.section == .argocd { kind = .pods }
        reload()
        if let client {
            Task {
                let available = await client.hasArgoCD()
                if context == name { argoAvailable = available }
            }
        }
        // Listing namespaces may be forbidden by RBAC; the picker then offers just the default.
        if let list = try? await client?.namespaces(), context == name {
            namespaces = list
        }
    }

    func select(kind: ResourceKind) {
        closeApplication()
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
        let kind = kind, namespace = listNamespace
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
        focusedApp?.stop()
    }

    func openApplication(_ object: KubeObject) {
        guard let client, let app else { return }
        focusedApp?.stop()
        let model = ArgoAppModel(client: client, application: ArgoApplication(object), cluster: self)
        model.start(app: app)
        focusedApp = model
    }

    func closeApplication() {
        // The diff tab holds this app's model, which stops updating once closed.
        if let focusedApp { closePanel(PanelTab.Request.diff(focusedApp).id) }
        focusedApp?.stop()
        focusedApp = nil
    }

    var activePanel: PanelTab? { panels.first { $0.id == activePanelID } }

    /// Shows the request's tab, reusing an open one for the same pod/resource.
    func openPanel(_ request: PanelTab.Request) {
        if !panels.contains(where: { $0.id == request.id }) {
            guard let app else { return }
            panels.append(PanelTab(request, app: app))
            if let s = splitIndex(of: activePanelID) {
                panelSplits[s].tabIDs.append(request.id)
            } else {
                panelSplits.append(PanelSplit(tabIDs: [request.id], activeID: request.id))
            }
        }
        selectPanel(request.id)
        isPanelVisible = true
    }

    func selectPanel(_ id: String) {
        guard let s = splitIndex(of: id) else { return }
        panelSplits[s].activeID = id
        activePanelID = id
    }

    func closePanel(_ id: String) {
        guard let index = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[index].stop()
        panels.remove(at: index)
        let s = detachPanel(id)
        if activePanelID == id {
            activePanelID = panelSplits.isEmpty ? nil : panelSplits[min(s ?? 0, panelSplits.count - 1)].activeID
        }
        if panels.isEmpty { isPanelVisible = false }
    }

    static let maxPanelSplits = 3

    /// Splitting moves the tab rather than copying it, so a pod never streams logs twice.
    func canSplitPanel(_ id: String) -> Bool {
        panelSplits.count < Self.maxPanelSplits && (splitIndex(of: id).map { panelSplits[$0].tabIDs.count } ?? 0) > 1
    }

    func splitPanelRight(_ id: String) {
        guard canSplitPanel(id), let s = detachPanel(id) else { return }
        panelSplits.insert(PanelSplit(tabIDs: [id], activeID: id), at: s + 1)
        activePanelID = id
    }

    /// Moves the tab to the split `offset` places away; a split left empty closes.
    func movePanel(_ id: String, by offset: Int) {
        guard let s = splitIndex(of: id), panelSplits.indices.contains(s + offset) else { return }
        let target = panelSplits[s + offset].id
        detachPanel(id)
        guard let t = panelSplits.firstIndex(where: { $0.id == target }) else { return }
        panelSplits[t].tabIDs.append(id)
        selectPanel(id)
    }

    func splitIndex(of id: String?) -> Int? {
        panelSplits.firstIndex { $0.tabIDs.contains(id ?? "") }
    }

    /// Removes the tab from its split, closing the split once empty; returns the split's index.
    @discardableResult
    private func detachPanel(_ id: String) -> Int? {
        guard let s = splitIndex(of: id), let i = panelSplits[s].tabIDs.firstIndex(of: id) else { return nil }
        panelSplits[s].tabIDs.remove(at: i)
        if panelSplits[s].tabIDs.isEmpty {
            panelSplits.remove(at: s)
        } else if panelSplits[s].activeID == id {
            panelSplits[s].activeID = panelSplits[s].tabIDs[min(i, panelSplits[s].tabIDs.count - 1)]
        }
        return s
    }
}
