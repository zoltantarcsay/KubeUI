import Foundation

public enum SortKey: Sendable, Comparable {
    case number(Double)
    case text(String)

    public static func < (lhs: SortKey, rhs: SortKey) -> Bool {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)): a < b
        case let (.text(a), .text(b)): a.localizedStandardCompare(b) == .orderedAscending
        case (.number, .text): true
        case (.text, .number): false
        }
    }
}

public struct Cell: Sendable, Hashable {
    public let text: String
    public let sortKey: SortKey

    public init(_ text: String, sortKey: SortKey? = nil) {
        self.text = text
        self.sortKey = sortKey ?? .text(text)
    }

    public static func number(_ n: Int?) -> Cell {
        Cell(n.map(String.init) ?? "", sortKey: .number(Double(n ?? -1)))
    }

    public static func age(_ date: Date?, now: Date) -> Cell {
        guard let date else { return Cell("", sortKey: .number(.infinity)) }
        let seconds = now.timeIntervalSince(date)
        return Cell(formatAge(seconds), sortKey: .number(seconds))
    }
}

extension SortKey: Hashable {}

public struct Column: Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let width: Double?
    public let value: @Sendable (KubeObject, Date) -> Cell

    public init(_ title: String, width: Double? = nil, _ value: @escaping @Sendable (KubeObject, Date) -> Cell) {
        self.title = title
        self.width = width
        self.value = value
    }

    public static let name = Column("Name", width: 260) { o, _ in Cell(o.name) }
    public static let namespace = Column("Namespace", width: 140) { o, _ in Cell(o.namespace ?? "") }
    public static let age = Column("Age", width: 70) { o, now in .age(o.creationDate, now: now) }

    static func text(_ title: String, width: Double? = nil, _ path: String) -> Column {
        Column(title, width: width) { o, _ in Cell(o.raw[path: path].string ?? "") }
    }

    static func number(_ title: String, width: Double? = 70, _ path: String) -> Column {
        Column(title, width: width) { o, _ in .number(o.raw[path: path].int) }
    }
}

/// A resource type shown in the sidebar, with k9s/kubectl-like columns.
public struct ResourceKind: Sendable, Identifiable, Hashable {
    public enum Section: String, Sendable, CaseIterable {
        case workloads = "Workloads", network = "Network", config = "Config", storage = "Storage", cluster = "Cluster"
    }

    /// The kubectl resource name, e.g. `deployments.apps`.
    public let id: String
    public let title: String
    public let symbol: String
    public let section: Section
    public let namespaced: Bool
    public let columns: [Column]

    public static func == (a: ResourceKind, b: ResourceKind) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var isPod: Bool { id == "pods" }
    public var isScalable: Bool { ["deployments.apps", "statefulsets.apps", "replicasets.apps"].contains(id) }
    public var isRestartable: Bool { ["deployments.apps", "statefulsets.apps", "daemonsets.apps"].contains(id) }

    public static func kind(id: String) -> ResourceKind? { all.first { $0.id == id } }
}

public extension ResourceKind {
    static let pods = ResourceKind(
        id: "pods", title: "Pods", symbol: "shippingbox", section: .workloads, namespaced: true,
        columns: [
            .name,
            Column("Ready", width: 60) { o, _ in
                let (ready, total) = PodStatus.readiness(o.raw)
                return Cell("\(ready)/\(total)", sortKey: .number(Double(ready)))
            },
            Column("Status", width: 130) { o, _ in Cell(PodStatus.reason(o.raw)) },
            Column("Restarts", width: 70) { o, _ in
                .number((o.raw["status.initContainerStatuses"].array + o.raw["status.containerStatuses"].array)
                    .reduce(0) { $0 + ($1["restartCount"].int ?? 0) })
            },
            .text("IP", width: 110, "status.podIP"),
            .text("Node", width: 160, "spec.nodeName"),
            .age,
        ]
    )

    static let all: [ResourceKind] = [
        pods,
        ResourceKind(
            id: "deployments.apps", title: "Deployments", symbol: "square.stack.3d.up", section: .workloads, namespaced: true,
            columns: [
                .name,
                Column("Ready", width: 70) { o, _ in
                    let ready = o.raw["status.readyReplicas"].int ?? 0
                    return Cell("\(ready)/\(o.raw["spec.replicas"].int ?? 0)", sortKey: .number(Double(ready)))
                },
                .number("Up-to-date", "status.updatedReplicas"),
                .number("Available", "status.availableReplicas"),
                .age,
            ]
        ),
        ResourceKind(
            id: "statefulsets.apps", title: "StatefulSets", symbol: "cylinder.split.1x2", section: .workloads, namespaced: true,
            columns: [
                .name,
                Column("Ready", width: 70) { o, _ in
                    let ready = o.raw["status.readyReplicas"].int ?? 0
                    return Cell("\(ready)/\(o.raw["spec.replicas"].int ?? 0)", sortKey: .number(Double(ready)))
                },
                .age,
            ]
        ),
        ResourceKind(
            id: "daemonsets.apps", title: "DaemonSets", symbol: "circle.grid.3x3", section: .workloads, namespaced: true,
            columns: [
                .name,
                .number("Desired", "status.desiredNumberScheduled"),
                .number("Current", "status.currentNumberScheduled"),
                .number("Ready", "status.numberReady"),
                .number("Up-to-date", "status.updatedNumberScheduled"),
                .number("Available", "status.numberAvailable"),
                .age,
            ]
        ),
        ResourceKind(
            id: "replicasets.apps", title: "ReplicaSets", symbol: "square.on.square", section: .workloads, namespaced: true,
            columns: [
                .name,
                .number("Desired", "spec.replicas"),
                .number("Current", "status.replicas"),
                .number("Ready", "status.readyReplicas"),
                .age,
            ]
        ),
        ResourceKind(
            id: "jobs.batch", title: "Jobs", symbol: "hammer", section: .workloads, namespaced: true,
            columns: [
                .name,
                Column("Status", width: 90) { o, _ in
                    let conditions = o.raw["status.conditions"].array
                    if conditions.contains(where: { $0["type"].string == "Complete" && $0["status"].string == "True" }) { return Cell("Complete") }
                    if conditions.contains(where: { $0["type"].string == "Failed" && $0["status"].string == "True" }) { return Cell("Failed") }
                    return Cell("Running")
                },
                Column("Completions", width: 90) { o, _ in
                    let done = o.raw["status.succeeded"].int ?? 0
                    return Cell("\(done)/\(o.raw["spec.completions"].int ?? 1)", sortKey: .number(Double(done)))
                },
                .age,
            ]
        ),
        ResourceKind(
            id: "cronjobs.batch", title: "CronJobs", symbol: "clock.arrow.circlepath", section: .workloads, namespaced: true,
            columns: [
                .name,
                .text("Schedule", width: 110, "spec.schedule"),
                Column("Suspend", width: 70) { o, _ in Cell(o.raw["spec.suspend"].bool == true ? "True" : "False") },
                Column("Active", width: 60) { o, _ in .number(o.raw["status.active"].array.count) },
                Column("Last Schedule", width: 100) { o, now in
                    .age(o.raw["status.lastScheduleTime"].string.flatMap(KubeObject.parseDate), now: now)
                },
                .age,
            ]
        ),
        ResourceKind(
            id: "services", title: "Services", symbol: "network", section: .network, namespaced: true,
            columns: [
                .name,
                .text("Type", width: 100, "spec.type"),
                .text("Cluster IP", width: 110, "spec.clusterIP"),
                Column("External IP", width: 140) { o, _ in
                    let ingress = o.raw["status.loadBalancer.ingress"].array.compactMap { $0["hostname"].string ?? $0["ip"].string }
                    let external = o.raw["spec.externalIPs"].array.compactMap(\.string)
                    return Cell((ingress + external).joined(separator: ","))
                },
                Column("Ports", width: 160) { o, _ in
                    Cell(o.raw["spec.ports"].array.map { p in
                        let port = p["port"].string ?? ""
                        let node = p["nodePort"].string.map { ":\($0)" } ?? ""
                        return "\(port)\(node)/\(p["protocol"].string ?? "TCP")"
                    }.joined(separator: ","))
                },
                .age,
            ]
        ),
        ResourceKind(
            id: "ingresses.networking.k8s.io", title: "Ingresses", symbol: "arrow.down.right.and.arrow.up.left", section: .network, namespaced: true,
            columns: [
                .name,
                .text("Class", width: 100, "spec.ingressClassName"),
                Column("Hosts", width: 220) { o, _ in
                    Cell(o.raw["spec.rules"].array.compactMap { $0["host"].string }.joined(separator: ","))
                },
                Column("Address", width: 160) { o, _ in
                    Cell(o.raw["status.loadBalancer.ingress"].array.compactMap { $0["hostname"].string ?? $0["ip"].string }.joined(separator: ","))
                },
                .age,
            ]
        ),
        ResourceKind(
            id: "configmaps", title: "ConfigMaps", symbol: "doc.text", section: .config, namespaced: true,
            columns: [
                .name,
                Column("Data", width: 60) { o, _ in .number(o.raw["data"].object.count + o.raw["binaryData"].object.count) },
                .age,
            ]
        ),
        ResourceKind(
            id: "secrets", title: "Secrets", symbol: "key", section: .config, namespaced: true,
            columns: [
                .name,
                .text("Type", width: 220, "type"),
                Column("Data", width: 60) { o, _ in .number(o.raw["data"].object.count) },
                .age,
            ]
        ),
        ResourceKind(
            id: "persistentvolumeclaims", title: "Volume Claims", symbol: "externaldrive", section: .storage, namespaced: true,
            columns: [
                .name,
                .text("Status", width: 80, "status.phase"),
                .text("Volume", width: 200, "spec.volumeName"),
                .text("Capacity", width: 80, "status.capacity.storage"),
                Column("Access Modes", width: 100) { o, _ in Cell(o.raw["spec.accessModes"].array.compactMap(\.string).joined(separator: ",")) },
                .text("Storage Class", width: 120, "spec.storageClassName"),
                .age,
            ]
        ),
        ResourceKind(
            id: "nodes", title: "Nodes", symbol: "server.rack", section: .cluster, namespaced: false,
            columns: [
                .name,
                Column("Status", width: 90) { o, _ in
                    let ready = o.raw["status.conditions"].array.first { $0["type"].string == "Ready" }
                    var status = ready?["status"].string == "True" ? "Ready" : "NotReady"
                    if o.raw["spec.unschedulable"].bool == true { status += ",SchedulingDisabled" }
                    return Cell(status)
                },
                Column("Roles", width: 120) { o, _ in
                    let roles = o.labels.keys.compactMap { key -> String? in
                        let prefix = "node-role.kubernetes.io/"
                        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
                    }
                    return Cell(roles.isEmpty ? "<none>" : roles.sorted().joined(separator: ","))
                },
                .text("Version", width: 110, "status.nodeInfo.kubeletVersion"),
                .age,
            ]
        ),
        ResourceKind(
            id: "namespaces", title: "Namespaces", symbol: "folder", section: .cluster, namespaced: false,
            columns: [.name, .text("Status", width: 90, "status.phase"), .age]
        ),
        ResourceKind(
            id: "events", title: "Events", symbol: "bolt", section: .cluster, namespaced: true,
            columns: [
                Column("Last Seen", width: 80) { o, now in
                    let raw = o.raw["lastTimestamp"].string ?? o.raw["eventTime"].string ?? o.raw["metadata.creationTimestamp"].string
                    return .age(raw.flatMap(KubeObject.parseDate), now: now)
                },
                .text("Type", width: 70, "type"),
                .text("Reason", width: 130, "reason"),
                Column("Object", width: 220) { o, _ in
                    Cell("\(o.raw["involvedObject.kind"].string?.lowercased() ?? "")/\(o.raw["involvedObject.name"].string ?? "")")
                },
                .text("Message", width: 400, "message"),
            ]
        ),
    ]
}

enum PodStatus {
    /// Native sidecars: init containers with `restartPolicy: Always` (Kubernetes 1.28+), which keep running.
    static func sidecarNames(_ pod: JSONValue) -> Set<String> {
        Set(pod["spec.initContainers"].array.filter { $0["restartPolicy"].string == "Always" }.compactMap { $0["name"].string })
    }

    /// Ready/total containers as kubectl counts them, sidecars included.
    static func readiness(_ pod: JSONValue) -> (ready: Int, total: Int) {
        let sidecars = sidecarNames(pod)
        let readySidecars = pod["status.initContainerStatuses"].array.filter {
            sidecars.contains($0["name"].string ?? "") && $0["started"].bool == true && $0["ready"].bool == true
        }.count
        let ready = pod["status.containerStatuses"].array.filter { $0["ready"].bool == true }.count
        return (ready + readySidecars, pod["spec.containers"].array.count + sidecars.count)
    }

    /// A condensed version of kubectl's pod STATUS column logic.
    static func reason(_ pod: JSONValue) -> String {
        if !pod["metadata.deletionTimestamp"].isNull { return "Terminating" }
        var reason = pod["status.reason"].string ?? pod["status.phase"].string ?? "Unknown"
        let initStatuses = pod["status.initContainerStatuses"].array
        let sidecars = sidecarNames(pod)
        for (i, status) in initStatuses.enumerated() {
            if status["state.terminated.exitCode"].int == 0 { continue }
            if sidecars.contains(status["name"].string ?? ""), status["started"].bool == true { continue }
            if let waiting = status["state.waiting.reason"].string, waiting != "PodInitializing" {
                return "Init:\(waiting)"
            }
            if let terminated = status["state.terminated.reason"].string { return "Init:\(terminated)" }
            return "Init:\(i)/\(pod["spec.initContainers"].array.count)"
        }
        for status in pod["status.containerStatuses"].array.reversed() {
            if let waiting = status["state.waiting.reason"].string {
                reason = waiting
            } else if let terminated = status["state.terminated.reason"].string {
                reason = terminated
            } else if !status["state.terminated"].isNull {
                let signal = status["state.terminated.signal"].int ?? 0
                reason = signal != 0 ? "Signal:\(signal)" : "ExitCode:\(status["state.terminated.exitCode"].int ?? 0)"
            }
        }
        return reason
    }
}

/// kubectl-style short durations ("45s", "3m12s", "5h", "12d").
public func formatAge(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    switch s {
    case ..<120: return "\(s)s"
    case ..<600: return "\(s / 60)m\(s % 60 == 0 ? "" : "\(s % 60)s")"
    case ..<10800: return "\(s / 60)m"
    case ..<28800: return "\(s / 3600)h\((s % 3600) / 60 == 0 ? "" : "\((s % 3600) / 60)m")"
    case ..<172_800: return "\(s / 3600)h"
    case ..<691_200: return "\(s / 86400)d\((s % 86400) / 3600 == 0 ? "" : "\((s % 86400) / 3600)h")"
    case ..<63_072_000: return "\(s / 86400)d"
    default: return "\(s / 31_536_000)y\((s % 31_536_000) / 86400)d"
    }
}
