import Foundation

/// An Argo CD `Application`, read from its custom resource (no Argo API or login needed).
public struct ArgoApplication: Sendable, Identifiable, Hashable {
    public struct Source: Sendable, Hashable {
        public let repoURL: String
        public let path: String?
        public let chart: String?
        public let targetRevision: String
        /// `ref` name used by other sources as `$ref/...` (multi-source apps).
        public let ref: String?
        public let helmValueFiles: [String]
        /// Inline Helm values, as YAML text, when set in the Application itself.
        public let helmValues: String?
        public let hasValuesObject: Bool
    }

    public struct Resource: Sendable, Hashable, Identifiable {
        public var id: String { "\(group)/\(kind)/\(namespace ?? "")/\(name)" }
        public let group: String
        public let version: String
        public let kind: String
        public let namespace: String?
        public let name: String
        public let syncStatus: String?
        public let health: String?
        public let healthMessage: String?
        public let hook: Bool
    }

    public struct Operation: Sendable, Hashable {
        public let phase: String
        public let message: String?
        public let revision: String?
        public let startedAt: Date?
        public let finishedAt: Date?
    }

    public let object: KubeObject
    public var id: String { object.id }
    public var name: String { object.name }
    public var namespace: String { object.namespace ?? "argocd" }
    public let project: String
    public let sources: [Source]
    public let destinationServer: String?
    public let destinationName: String?
    public let destinationNamespace: String?
    public let syncStatus: String
    public let healthStatus: String
    public let healthMessage: String?
    /// Revision(s) Argo last compared against; one per source for multi-source apps.
    public let syncedRevisions: [String]
    public let operation: Operation?
    public let resources: [Resource]
    public let images: [String]
    public let autoSync: Bool
    /// The ApplicationSet that generated this app, if any.
    public let applicationSet: String?

    public init(_ object: KubeObject) {
        self.object = object
        let raw = object.raw
        project = raw["spec.project"].string ?? "default"
        let sourceJSON = raw["spec.sources"].array.isEmpty ? [raw["spec.source"]].filter { !$0.isNull } : raw["spec.sources"].array
        sources = sourceJSON.map { s in
            Source(
                repoURL: s["repoURL"].string ?? "",
                path: s["path"].string,
                chart: s["chart"].string,
                targetRevision: s["targetRevision"].string ?? "HEAD",
                ref: s["ref"].string,
                helmValueFiles: s["helm.valueFiles"].array.compactMap(\.string),
                helmValues: s["helm.values"].string,
                hasValuesObject: !s["helm.valuesObject"].isNull
            )
        }
        destinationServer = raw["spec.destination.server"].string
        destinationName = raw["spec.destination.name"].string
        destinationNamespace = raw["spec.destination.namespace"].string
        syncStatus = raw["status.sync.status"].string ?? "Unknown"
        healthStatus = raw["status.health.status"].string ?? "Unknown"
        healthMessage = raw["status.health.message"].string
        let revisions = raw["status.sync.revisions"].array.compactMap(\.string)
        syncedRevisions = revisions.isEmpty ? [raw["status.sync.revision"].string].compactMap { $0 } : revisions
        if let phase = raw["status.operationState.phase"].string {
            let op = raw["status.operationState"]
            let revs = op["syncResult.revisions"].array.compactMap(\.string)
            operation = Operation(
                phase: phase,
                message: op["message"].string,
                revision: op["syncResult.revision"].string ?? revs.first,
                startedAt: op["startedAt"].string.flatMap(KubeObject.parseDate),
                finishedAt: op["finishedAt"].string.flatMap(KubeObject.parseDate)
            )
        } else {
            operation = nil
        }
        resources = raw["status.resources"].array.map { r in
            Resource(
                group: r["group"].string ?? "",
                version: r["version"].string ?? "",
                kind: r["kind"].string ?? "",
                namespace: r["namespace"].string,
                name: r["name"].string ?? "",
                syncStatus: r["status"].string,
                health: r["health.status"].string,
                healthMessage: r["health.message"].string,
                hook: r["hook"].bool == true
            )
        }
        images = raw["status.summary.images"].array.compactMap(\.string)
        autoSync = !raw["spec.syncPolicy.automated"].isNull
        applicationSet = raw["metadata.ownerReferences"].array.first { $0["kind"].string == "ApplicationSet" }?["name"].string
    }

    /// True once Argo has synced `sha` (full or abbreviated) and the sync operation finished.
    public func hasDeployed(_ sha: String) -> Bool {
        syncedRevisions.contains { $0.hasPrefix(sha) || sha.hasPrefix($0) } && syncStatus == "Synced"
            && (operation == nil || operation?.phase == "Succeeded")
    }
}

public extension KubeClient {
    /// Whether the cluster serves Argo CD's API group (discovery is readable even with tight RBAC).
    func hasArgoCD() async -> Bool {
        guard let out = try? await kubectl.runString(args(["api-resources", "--api-group=argoproj.io", "-o", "name"])) else { return false }
        return out.contains("applications.argoproj.io")
    }

    /// Asks Argo to re-read git now instead of at its next poll.
    func refresh(_ app: ArgoApplication, hard: Bool = false) async throws {
        _ = try await kubectl.run(args(["annotate", "applications.argoproj.io", app.name,
                                        "argocd.argoproj.io/refresh=\(hard ? "hard" : "normal")", "--overwrite"], namespace: app.namespace))
    }

    /// Starts a sync to the app's target revision, the same way the Argo UI's Sync button does.
    func sync(_ app: ArgoApplication) async throws {
        let patch = #"{"operation":{"initiatedBy":{"username":"kubeui"},"sync":{"syncStrategy":{"hook":{}}}}}"#
        _ = try await kubectl.run(args(["patch", "applications.argoproj.io", app.name, "--type", "merge", "-p", patch], namespace: app.namespace))
    }

    /// Pods selected by a managed workload, via its own label selector.
    func pods(selectedBy workload: ArgoApplication.Resource) async throws -> [KubeObject] {
        guard let kind = ResourceKind.all.first(where: { $0.title.dropLast() == workload.kind || $0.id.hasPrefix(workload.kind.lowercased() + "s") }),
              let namespace = workload.namespace else { return [] }
        let object = try await get(kind, name: workload.name, namespace: namespace)
        let labels = object.raw["spec.selector.matchLabels"].object.compactMapValues(\.string)
        guard !labels.isEmpty else { return [] }
        let selector = labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let data = try await kubectl.run(args(["get", "pods", "-l", selector, "-o", "json"], namespace: namespace))
        return try JSONValue.parse(data)["items"].array.map(KubeObject.init)
    }
}
