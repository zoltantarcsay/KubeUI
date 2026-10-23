import AppKit
import KubeKit
import SwiftUI

/// One Argo CD application seen through all three layers: its GitOps source (the user's clone),
/// Argo's sync state, and the live workloads and pods it manages.
@Observable
final class ArgoAppModel {
    /// A change being followed from push to running pods.
    struct Rollout {
        /// The pushed commit, when pushed straight to the tracked branch.
        let sha: String?
        /// Argo's revision before the push; with a PR, any new revision means it was merged.
        let baseline: [String]
        let pushedAt: Date
        let pullRequest: URL?
    }

    enum StageState { case idle, waiting, working, done, failed }

    struct Stage {
        let state: StageState
        let title: String
        let detail: String
    }

    let client: KubeClient
    private(set) var application: ArgoApplication
    private weak var cluster: ClusterModel?
    private(set) var workloads: [KubeObject] = []
    private(set) var pods: [KubeObject] = []

    private(set) var repo: GitRepo?
    private(set) var repoURL: String?
    private(set) var layers: [ValueLayer] = []
    var envBlock: [String]?
    private(set) var branch: String?
    private(set) var head: GitRepo.Commit?
    private(set) var changes: [GitRepo.Change] = []
    private(set) var aheadBehind: (ahead: Int, behind: Int)?
    private(set) var diff = ""
    var rollout: Rollout?

    /// Short description of a running git/Argo operation.
    private(set) var busy: String?
    var alert: String?
    var now = Date()

    private var app: AppModel?
    private var tasks: [Task<Void, Never>] = []
    private var workloadsByKind: [String: [String: KubeObject]] = [:]

    init(client: KubeClient, application: ArgoApplication, cluster: ClusterModel) {
        self.client = client
        self.application = application
        self.cluster = cluster
    }

    /// The source holding the values files the user edits (the `$values` ref repo when present).
    var valuesSource: ArgoApplication.Source? {
        application.sources.first { $0.ref != nil } ?? application.sources.first { $0.path != nil } ?? application.sources.first
    }

    var trackedBranch: String { valuesSource?.targetRevision ?? "HEAD" }

    func start(app: AppModel) {
        self.app = app
        let name = application.name, ns = application.namespace
        tasks.append(Task { [weak self] in
            guard let self else { return }
            do {
                for try await update in client.watch(.argoApplications, namespace: ns, name: name) {
                    switch update {
                    case .snapshot(let list): if let o = list.first { apply(ArgoApplication(o)) }
                    case .event(let e) where e.kind != .deleted: apply(ArgoApplication(e.object))
                    default: break
                    }
                }
            } catch {}
        })
        if let dest = application.destinationNamespace {
            for kindID in ["pods", "deployments.apps", "statefulsets.apps", "daemonsets.apps"] {
                guard let kind = ResourceKind.kind(id: kindID) else { continue }
                tasks.append(Task { [weak self] in
                    guard let self else { return }
                    do {
                        for try await update in client.watch(kind, namespace: dest) { receive(update, kind: kindID) }
                    } catch {}
                })
            }
        }
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.now = Date()
            }
        })
        Task { await openRepo() }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    private func apply(_ updated: ArgoApplication) {
        application = updated
        if layers.isEmpty, repo != nil { reloadLayers() }
    }

    private func receive(_ update: KubeClient.WatchUpdate, kind: String) {
        var objects = workloadsByKind[kind] ?? [:]
        switch update {
        case .snapshot(let list): objects = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        case .event(let e): objects[e.object.id] = e.kind == .deleted ? nil : e.object
        }
        workloadsByKind[kind] = objects
        if kind == "pods" {
            pods = Array(objects.values)
        } else {
            workloads = workloadsByKind.filter { $0.key != "pods" }.flatMap(\.value.values)
        }
    }

    // MARK: - Live layer

    /// The live object behind a managed resource, for workloads.
    func live(_ resource: ArgoApplication.Resource) -> KubeObject? {
        workloads.first { $0.kind == resource.kind && $0.name == resource.name && $0.namespace == resource.namespace }
    }

    func pods(of workload: KubeObject) -> [KubeObject] {
        let selector = workload.raw["spec.selector.matchLabels"].object.compactMapValues(\.string)
        guard !selector.isEmpty else { return [] }
        return pods.filter { pod in selector.allSatisfy { pod.labels[$0.key] == $0.value } }
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    var managedPods: [KubeObject] {
        application.resources.compactMap(live).flatMap(pods(of:))
    }

    // MARK: - Source layer

    func openRepo() async {
        guard let app, let source = valuesSource else { return }
        repoURL = source.repoURL
        guard let root = app.linkedRoot(for: source.repoURL), let kubectl = await app.ensureKubectl() else {
            repo = nil
            return
        }
        do {
            repo = try await GitRepo.open(root, environment: kubectl.environment)
            reloadLayers()
            await refreshGit(fetch: true)
        } catch {
            repo = nil
            alert = "Couldn't open \(root.path) as a git repository: \(error.localizedDescription)"
        }
    }

    /// Links a local clone, checking that its origin is the app's repo.
    func link(_ folder: URL) async {
        guard let app, let repoURL = valuesSource?.repoURL, let kubectl = await app.ensureKubectl() else { return }
        do {
            let candidate = try await GitRepo.open(folder, environment: kubectl.environment)
            let origin = try await candidate.remoteURL()
            if !GitRepo.sameRepo(origin, repoURL) {
                alert = "Linked anyway, but this clone's origin (\(origin)) doesn't match the app's repo (\(repoURL))."
            }
            app.link(repoURL: repoURL, to: candidate.root)
            await openRepo()
        } catch {
            alert = "\(folder.path) isn't a git clone: \(error.localizedDescription)"
        }
    }

    func reloadLayers() {
        guard let app else { return }
        layers = HelmValues.layers(for: application) { app.linkedRoot(for: $0) }
        let blocks = HelmValues.envBlocks(layers)
        if envBlock == nil || !blocks.contains(envBlock!) { envBlock = preferredBlock(blocks) }
    }

    /// Prefers the backend container's env, the common case for app config.
    private func preferredBlock(_ blocks: [[String]]) -> [String]? {
        blocks.first { $0.suffix(2) == ["backend", "env"] } ?? blocks.first
    }

    var envBlocks: [[String]] { HelmValues.envBlocks(layers) }

    var env: [EnvVar] {
        guard let envBlock else { return [] }
        return HelmValues.env(envBlock, in: layers)
    }

    func refreshGit(fetch: Bool) async {
        guard let repo else { return }
        do {
            branch = try await repo.currentBranch()
            head = try await repo.head()
            changes = try await repo.status()
            diff = changes.isEmpty ? "" : try await repo.diff()
            aheadBehind = try await repo.aheadBehind(fetch: fetch)
        } catch {
            alert = error.localizedDescription
        }
    }

    /// Writes an env var into a layer's file, keeping the rest of the file as it is.
    func setEnv(_ key: String, value: String, layer index: Int) {
        guard let envBlock else { return }
        edit(layer: index) { $0.set(envBlock, key: key, value: value) }
    }

    func removeEnv(_ key: String, layer index: Int) {
        guard let envBlock else { return }
        edit(layer: index) { $0.remove(envBlock, key: key) }
    }

    private func edit(layer index: Int, _ change: (inout YAMLEdit) -> Void) {
        guard layers.indices.contains(index), let file = layers[index].file else { return }
        var yaml = YAMLEdit(layers[index].text)
        change(&yaml)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try yaml.text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            alert = error.localizedDescription
        }
        reloadLayers()
        Task { await refreshGit(fetch: false) }
    }

    func discardChanges() async {
        await run("Discarding") { try await $0.discard(self.changes) }
        reloadLayers()
    }

    func pull() async {
        await run("Pulling") { try await $0.pull() }
        reloadLayers()
    }

    /// Commits the changed files and pushes to the current branch, then follows the rollout.
    func commitAndPush(_ message: String) async {
        let baseline = application.syncedRevisions
        var pushed: GitRepo.Commit?
        await run("Pushing") { repo in
            pushed = try await repo.commit(message, paths: self.changes.map(\.path))
            try await repo.push()
        }
        guard let pushed else { return }
        rollout = Rollout(sha: pushed.sha, baseline: baseline, pushedAt: Date(), pullRequest: nil)
        await refreshArgo()
    }

    /// Commits on a new branch, pushes it, opens GitHub's PR page and returns to the tracked branch.
    func commitToPullRequest(_ message: String, branchName: String) async {
        let baseline = application.syncedRevisions
        let base = branch ?? trackedBranch
        var prURL: URL?
        await run("Pushing \(branchName)") { repo in
            try await repo.createBranch(branchName)
            _ = try await repo.commit(message, paths: self.changes.map(\.path))
            try await repo.push()
            prURL = GitRepo.pullRequestURL(remote: try await repo.remoteURL(), branch: branchName, base: self.trackedBranch)
            try await repo.switchBranch(base)
        }
        guard busyFailed == false else { return }
        rollout = Rollout(sha: nil, baseline: baseline, pushedAt: Date(), pullRequest: prURL)
        if let prURL { NSWorkspace.shared.open(prURL) }
        reloadLayers()
    }

    private var busyFailed = false

    private func run(_ title: String, _ operation: @escaping (GitRepo) async throws -> Void) async {
        guard let repo else { return }
        busy = title
        busyFailed = false
        do {
            try await operation(repo)
        } catch {
            busyFailed = true
            alert = error.localizedDescription
        }
        busy = nil
        await refreshGit(fetch: false)
    }

    // MARK: - Argo layer

    func refreshArgo() async {
        do { try await client.refresh(application) } catch { alert = error.localizedDescription }
    }

    func syncArgo() async {
        do { try await client.sync(application) } catch { alert = error.localizedDescription }
    }

    // MARK: - Pipeline

    var sourceStage: Stage {
        guard repo != nil else {
            return Stage(state: .idle, title: "Not linked", detail: repoURL.map { "Link your clone of \(shortRepo($0))" } ?? "No git source")
        }
        let branchText = branch ?? "?"
        if let busy { return Stage(state: .working, title: busy + "…", detail: branchText) }
        if branchText != trackedBranch, trackedBranch != "HEAD" {
            return Stage(state: .failed, title: "On \(branchText)", detail: "Argo tracks \(trackedBranch)")
        }
        if let rollout, rollout.pullRequest != nil {
            return Stage(state: .waiting, title: "PR opened", detail: "Waiting for merge into \(trackedBranch)")
        }
        if !changes.isEmpty { return Stage(state: .waiting, title: "\(changes.count) uncommitted", detail: "\(branchText) @ \(head?.short ?? "")") }
        if let ab = aheadBehind, ab.ahead > 0 { return Stage(state: .waiting, title: "\(ab.ahead) unpushed", detail: branchText) }
        if let ab = aheadBehind, ab.behind > 0 { return Stage(state: .waiting, title: "\(ab.behind) behind", detail: "Pull to update \(branchText)") }
        if let rollout, rollout.sha != nil { return Stage(state: .done, title: "Pushed \(String(rollout.sha!.prefix(7)))", detail: head?.subject ?? "") }
        return Stage(state: .done, title: "\(branchText) @ \(head?.short ?? "")", detail: head?.subject ?? "")
    }

    /// True once Argo has the rollout's commit (or, for a PR, any revision after the push).
    var rolloutReachedArgo: Bool {
        guard let rollout else { return false }
        if let sha = rollout.sha { return application.syncedRevisions.contains { $0.hasPrefix(sha) } }
        return application.syncedRevisions != rollout.baseline
    }

    var argoStage: Stage {
        let app = application
        let revision = app.syncedRevisions.last.map { String($0.prefix(7)) } ?? "?"
        if let op = app.operation, op.phase == "Running" {
            return Stage(state: .working, title: "Syncing…", detail: op.message ?? revision)
        }
        if let op = app.operation, ["Failed", "Error"].contains(op.phase), rollout == nil || (op.startedAt ?? .distantPast) > rollout!.pushedAt {
            return Stage(state: .failed, title: "Sync \(op.phase.lowercased())", detail: op.message ?? "")
        }
        if rollout != nil, !rolloutReachedArgo {
            return Stage(state: .waiting, title: "Waiting for Argo", detail: rollout?.sha.map { "to pick up \(String($0.prefix(7)))" } ?? "to see the merge")
        }
        let state: StageState = app.syncStatus == "Synced" ? .done : (app.syncStatus == "OutOfSync" ? .waiting : .idle)
        return Stage(state: state, title: "\(app.syncStatus) @ \(revision)", detail: app.autoSync ? "Auto-sync" : "Manual sync")
    }

    var clusterStage: Stage {
        let health = application.healthStatus
        let pods = managedPods
        let ready = pods.filter { $0.raw["status.containerStatuses"].array.allSatisfy { $0["ready"].bool == true } && $0.raw["metadata.deletionTimestamp"].isNull }
        let podText = "\(ready.count)/\(pods.count) pods ready"
        if let rollout, rolloutReachedArgo {
            let fresh = pods.filter { ($0.creationDate ?? .distantPast) > rollout.pushedAt.addingTimeInterval(-5) }
            let settled = health == "Healthy" && !pods.contains { !$0.raw["metadata.deletionTimestamp"].isNull }
            if settled {
                let detail = fresh.isEmpty ? "No pods restarted (config-only change?)" : "\(fresh.count) new pod\(fresh.count == 1 ? "" : "s"), \(podText)"
                return Stage(state: .done, title: "Rolled out", detail: detail)
            }
            return Stage(state: .working, title: "Rolling out…", detail: "\(fresh.count) new, \(podText)")
        }
        switch health {
        case "Healthy": return Stage(state: .done, title: "Healthy", detail: podText)
        case "Progressing": return Stage(state: .working, title: "Progressing", detail: podText)
        case "Degraded", "Missing": return Stage(state: .failed, title: health, detail: application.healthMessage ?? podText)
        default: return Stage(state: .idle, title: health, detail: podText)
        }
    }

    func shortRepo(_ url: String) -> String {
        GitRepo.githubSlug(url) ?? URL(string: url)?.lastPathComponent ?? url
    }

    func openPanel(_ request: PanelTab.Request) {
        cluster?.openPanel(request)
    }

    var context: String { client.context }
}
