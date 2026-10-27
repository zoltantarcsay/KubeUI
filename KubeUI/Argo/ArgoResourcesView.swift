import KubeKit
import SwiftUI

/// Resources Argo CD manages for the app, with live workload readiness and their pods.
struct ArgoResourcesView: View {
    let model: ArgoAppModel
    /// Workloads start expanded so their pods are visible; this remembers the ones collapsed.
    @State private var collapsed = Set<String>()

    var body: some View {
        List {
            ForEach(grouped, id: \.kind) { group in
                Section(group.kind) {
                    ForEach(group.resources) { resource in
                        if let live = model.live(resource) {
                            DisclosureGroup(isExpanded: Binding(
                                get: { !collapsed.contains(resource.id) },
                                set: { if $0 { collapsed.remove(resource.id) } else { collapsed.insert(resource.id) } }
                            )) {
                                ForEach(model.pods(of: live)) { pod in podRow(pod) }
                            } label: {
                                resourceRow(resource, live: live)
                            }
                        } else {
                            resourceRow(resource, live: nil)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.application.resources.isEmpty {
                ContentUnavailableView("No Managed Resources", systemImage: "square.dashed")
            }
        }
    }

    private var grouped: [(kind: String, resources: [ArgoApplication.Resource])] {
        let order = ["Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Service", "Ingress", "ConfigMap", "Secret"]
        let groups = Dictionary(grouping: model.application.resources.filter { !$0.hook }, by: \.kind)
        return groups.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            .map { ($0, groups[$0]!.sorted { $0.name < $1.name }) }
    }

    private func resourceRow(_ r: ArgoApplication.Resource, live: KubeObject?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(r.kind)).foregroundStyle(.secondary).frame(width: 18)
            Text(r.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let live {
                let ready = live.raw["status.readyReplicas"].int ?? live.raw["status.numberReady"].int ?? 0
                let desired = live.raw["spec.replicas"].int ?? live.raw["status.desiredNumberScheduled"].int ?? 0
                Text("\(ready)/\(desired) ready").font(.callout.monospacedDigit()).foregroundStyle(ready == desired ? .secondary : Color.orange)
            }
            if let health = r.health { badge(health) }
            badge(r.syncStatus ?? "Unknown")
        }
        .contextMenu {
            Button("Show YAML") { open(r, .yaml) }
            Button("Describe") { open(r, .describe) }
        }
        .onTapGesture(count: 2) { open(r, .yaml) }
    }

    private func podRow(_ pod: KubeObject) -> some View {
        let status = ResourceKind.pods.columns.first { $0.title == "Status" }!.value(pod, model.now).text
        let ready = ResourceKind.pods.columns.first { $0.title == "Ready" }!.value(pod, model.now).text
        let restarts = ResourceKind.pods.columns.first { $0.title == "Restarts" }!.value(pod, model.now).text
        let isNew = model.rollout.map { (pod.creationDate ?? .distantPast) > $0.pushedAt.addingTimeInterval(-5) } ?? false
        return HStack(spacing: 8) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 18)
            Text(pod.name).lineLimit(1).truncationMode(.middle)
            if isNew {
                Text("NEW").font(.caption2.weight(.bold)).padding(.horizontal, 4).background(Capsule().fill(.green.opacity(0.2)))
                    .help("Created after your push")
            }
            Spacer()
            Text(ready).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text("↻\(restarts)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).help("Restarts")
            Text(formatAge(model.now.timeIntervalSince(pod.creationDate ?? model.now))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            badge(status)
        }
        .contextMenu {
            Button("Show Logs") { model.openPanel(.logs(ref(pod))) }
            Button("Browse Files") { model.openPanel(.files(ref(pod))) }
            Button("Open Shell") { model.openPanel(.shell(ref(pod), container: nil)) }
            Button("Show YAML") { model.openPanel(.text(TextTarget(context: model.context, kindID: "pods", name: pod.name, namespace: pod.namespace, mode: .yaml))) }
        }
        .onTapGesture(count: 2) { model.openPanel(.text(TextTarget(context: model.context, kindID: "pods", name: pod.name, namespace: pod.namespace, mode: .yaml))) }
    }

    private func ref(_ pod: KubeObject) -> PodRef {
        PodRef(context: model.context, namespace: pod.namespace ?? "", pod: pod.name, containers: pod.containerNames)
    }

    private func open(_ r: ArgoApplication.Resource, _ mode: TextTarget.Mode) {
        let kindID = ResourceKind.all.first { $0.title.dropLast() == r.kind }?.id ?? r.kind.lowercased()
        model.openPanel(.text(TextTarget(context: model.context, kindID: kindID, name: r.name, namespace: r.namespace, mode: mode)))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(argoTint(text).opacity(0.15)))
            .foregroundStyle(argoTint(text))
    }

    private func symbol(_ kind: String) -> String {
        ResourceKind.all.first { $0.title.dropLast() == kind }?.symbol ?? "cube"
    }
}
