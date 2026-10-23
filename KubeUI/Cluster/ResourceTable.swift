import KubeKit
import SwiftUI

struct ResourceTable: View {
    @Bindable var model: ClusterModel
    @State private var pendingDelete: [KubeObject] = []
    @State private var pendingRestart: KubeObject?
    @State private var scaleTarget: KubeObject?
    @State private var scaleText = ""
    @State private var actionError: String?

    var body: some View {
        let columns = Array(model.columns.enumerated())
        let rows = model.rows
        Table(rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumnForEach(columns, id: \.element.id) { index, column in
                TableColumn(column.title, value: \ResourceRow.[sort: index]) { row in
                    cell(row, index: index, title: column.title)
                }
                .width(min: 40, ideal: column.width ?? 100)
            }
        }
        .id(model.kind.id + (model.namespace == nil ? "*" : ""))
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: objects(ids))
        } primaryAction: { ids in
            guard let object = objects(ids).first else { return }
            if model.kind.isPod {
                openFiles(object)
            } else if model.kind.isArgoApplication {
                model.openApplication(object)
            } else {
                openText(object, .yaml)
            }
        }
        .overlay { overlay(isEmpty: rows.isEmpty) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.kind.isArgoApplication { RepoLinkBanner(model: model) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar(count: rows.count) }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                perform(pendingDelete) { client, kind, o in try await client.delete(kind, name: o.name, namespace: o.namespace) }
            }
        } message: {
            Text("Context: \(model.context ?? "")\nThis can't be undone.")
        }
        .confirmationDialog("Restart \(pendingRestart?.name ?? "")?", isPresented: Binding(get: { pendingRestart != nil }, set: { if !$0 { pendingRestart = nil } })) {
            Button("Restart") {
                perform(pendingRestart.map { [$0] } ?? []) { client, kind, o in try await client.restart(kind, name: o.name, namespace: o.namespace) }
            }
        } message: {
            Text("Performs a rolling restart in context \(model.context ?? "").")
        }
        .alert("Scale \(scaleTarget?.name ?? "")", isPresented: Binding(get: { scaleTarget != nil }, set: { if !$0 { scaleTarget = nil } })) {
            TextField("Replicas", text: $scaleText)
            Button("Scale") {
                guard let replicas = Int(scaleText), let target = scaleTarget else { return }
                perform([target]) { client, kind, o in try await client.scale(kind, name: o.name, namespace: o.namespace, replicas: replicas) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Context: \(model.context ?? "")")
        }
        .alert("Action failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
        } message: {
            Text(actionError ?? "")
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete \(model.kind.title.lowercased().dropLast()) \(pendingDelete[0].name)?" : "Delete \(pendingDelete.count) \(model.kind.title.lowercased())?"
    }

    @ViewBuilder
    private func cell(_ row: ResourceRow, index: Int, title: String) -> some View {
        let text = row.cells.indices.contains(index) ? row.cells[index].text : ""
        switch title {
        case "Name":
            Label {
                Text(text).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: model.kind.symbol).foregroundStyle(.secondary)
            }
        case "Status", "Type":
            Text(text).foregroundStyle(statusColor(text))
        case "Sync", "Health":
            Text(text).foregroundStyle(argoTint(text))
        default:
            Text(text).lineLimit(1).monospacedDigit()
        }
    }

    private func statusColor(_ status: String) -> Color {
        let bad = ["Error", "Failed", "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "OOMKilled", "NotReady", "Warning", "Evicted"]
        let busy = ["Pending", "ContainerCreating", "Terminating", "PodInitializing"]
        if bad.contains(where: status.contains) || status.hasPrefix("Init:") && status.contains("Err") { return .red }
        if busy.contains(where: status.contains) || status.hasPrefix("Init:") { return .orange }
        return .primary
    }

    @ViewBuilder
    private func overlay(isEmpty: Bool) -> some View {
        if let error = model.error {
            ContentUnavailableView {
                Label("Can't load \(model.kind.title)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Try Again") { model.reload() }
            }
        } else if model.isLoading {
            ProgressView()
        } else if isEmpty {
            ContentUnavailableView(model.search.isEmpty ? "No \(model.kind.title)" : "No Matches", systemImage: model.kind.symbol)
        }
    }

    private func statusBar(count: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isLive ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
                .help(model.isLive ? "Watching for changes" : "Not connected")
            Text(model.selection.isEmpty ? "\(count) items" : "\(model.selection.count) of \(count) selected")
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
    }

    private func objects(_ ids: Set<String>) -> [KubeObject] {
        ids.compactMap { model.objects[$0] }.sorted { $0.name < $1.name }
    }

    @ViewBuilder
    private func menu(for objects: [KubeObject]) -> some View {
        if let first = objects.first {
            if model.kind.isArgoApplication, objects.count == 1 {
                Button("Open Application") { model.openApplication(first) }
                Divider()
            }
            if model.kind.isPod, objects.count == 1 {
                Button("Browse Files") { openFiles(first) }
                Button("Show Logs") { openLogs(first) }
                containerMenu("Open Shell", first) { container in
                    if let ref = podRef(first) { model.openPanel(.shell(ref, container: container)) }
                }
                containerMenu("Open Shell in Terminal", first) { container in openShell(first, container: container) }
                Divider()
            }
            if objects.count == 1 {
                Button("Show YAML") { openText(first, .yaml) }
                Button("Describe") { openText(first, .describe) }
                Divider()
            }
            if model.kind.isScalable, objects.count == 1 {
                Button("Scale…") {
                    scaleText = first.raw["spec.replicas"].string ?? "1"
                    scaleTarget = first
                }
            }
            if model.kind.isRestartable, objects.count == 1 {
                Button("Restart") { pendingRestart = first }
            }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(objects.map(\.name).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = objects }
        }
    }

    @ViewBuilder
    private func containerMenu(_ title: String, _ pod: KubeObject, action: @escaping (String?) -> Void) -> some View {
        let containers = pod.containerNames
        if containers.count > 1 {
            Menu(title) {
                ForEach(containers, id: \.self) { name in Button(name) { action(name) } }
            }
        } else {
            Button(title) { action(containers.first) }
        }
    }

    private func podRef(_ pod: KubeObject) -> PodRef? {
        guard let context = model.context, let namespace = pod.namespace else { return nil }
        return PodRef(context: context, namespace: namespace, pod: pod.name, containers: pod.containerNames)
    }

    private func openFiles(_ pod: KubeObject) {
        if let ref = podRef(pod) { model.openPanel(.files(ref)) }
    }

    private func openLogs(_ pod: KubeObject) {
        if let ref = podRef(pod) { model.openPanel(.logs(ref)) }
    }

    private func openText(_ object: KubeObject, _ mode: TextTarget.Mode) {
        guard let context = model.context else { return }
        model.openPanel(.text(TextTarget(context: context, kindID: model.kind.id, name: object.name, namespace: object.namespace, mode: mode)))
    }

    private func openShell(_ pod: KubeObject, container: String?) {
        guard let client = model.client, let namespace = pod.namespace else { return }
        do {
            try Terminal.run(client.shellCommand(pod: pod.name, namespace: namespace, container: container))
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func perform(_ objects: [KubeObject], _ action: @escaping (KubeClient, ResourceKind, KubeObject) async throws -> Void) {
        guard let client = model.client else { return }
        let kind = model.kind
        Task {
            do {
                for object in objects { try await action(client, kind, object) }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// Offers to link local clones of the GitOps repos the listed Argo CD apps deploy from.
private struct RepoLinkBanner: View {
    let model: ClusterModel
    @Environment(AppModel.self) private var app
    @AppStorage("dismissedRepoBanner") private var dismissed = false
    @State private var message: String?

    var body: some View {
        let repos = unlinked
        if !repos.isEmpty, !dismissed {
            HStack(spacing: 10) {
                Image(systemName: "link.badge.plus").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Argo CD detected. Link your GitOps clone to edit app configuration here.").font(.callout)
                    Text(repos.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Link Repository…") { link(repos[0]) }
                Button { dismissed = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide; you can link later from an application's Source card")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .alert("Link Repository", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            } message: {
                Text(message ?? "")
            }
        }
    }

    private var unlinked: [String] {
        let urls = model.objects.values.flatMap { ArgoApplication($0).sources.map(\.repoURL) }
        var seen: [String] = []
        for url in urls where !url.isEmpty && app.linkedRoot(for: url) == nil && !seen.contains(where: { GitRepo.sameRepo($0, url) }) {
            seen.append(url)
        }
        return seen
    }

    private func link(_ repoURL: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link"
        panel.message = "Choose your local clone of \(repoURL)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            switch await app.linkRepo(url, to: repoURL) {
            case .failed(let text): message = text
            case .linked(let warning): message = warning
            }
        }
    }
}
