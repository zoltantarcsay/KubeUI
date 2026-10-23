import KubeKit
import SwiftUI

/// Finder "Get Info"-style summary of the selected object.
struct InspectorView: View {
    let model: ClusterModel

    var body: some View {
        if let object = model.selectedObjects.first, model.selection.count == 1 {
            Form {
                Section {
                    LabeledContent("Name") { Text(object.name).textSelection(.enabled) }
                    LabeledContent("Kind", value: object.kind)
                    if let ns = object.namespace { LabeledContent("Namespace", value: ns) }
                    if let created = object.creationDate {
                        LabeledContent("Created") { Text(created, format: .dateTime) }
                    }
                    ForEach(object.raw["metadata.ownerReferences"].array.indices, id: \.self) { i in
                        let owner = object.raw["metadata.ownerReferences"][i]
                        LabeledContent("Owner", value: "\(owner["kind"].string ?? "")/\(owner["name"].string ?? "")")
                    }
                }
                if object.kind == "Pod" {
                    ForEach(containers(object), id: \.spec) { c in
                        ContainerSection(pod: object, spec: c.spec, role: c.role)
                    }
                    Section {
                        LabeledContent("Node", value: object.raw["spec.nodeName"].string ?? "—")
                        LabeledContent("Pod IP", value: object.raw["status.podIP"].string ?? "—")
                        LabeledContent("QoS", value: object.raw["status.qosClass"].string ?? "—")
                        let secrets = object.raw["spec.imagePullSecrets"].array.compactMap { $0["name"].string }
                        if !secrets.isEmpty { LabeledContent("Pull Secrets", value: secrets.joined(separator: ", ")) }
                    }
                }
                dictionarySection("Labels", object.labels)
                dictionarySection("Annotations", object.annotations.filter { $0.key != "kubectl.kubernetes.io/last-applied-configuration" })
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(model.selection.isEmpty ? "No Selection" : "\(model.selection.count) Items", systemImage: "info.circle")
        }
    }

    /// Regular containers first, then native sidecars and init containers.
    private func containers(_ pod: KubeObject) -> [(spec: JSONValue, role: String?)] {
        let regular = pod.raw["spec.containers"].array.map { (spec: $0, role: String?.none) }
        let initial = pod.raw["spec.initContainers"].array.map { (spec: $0, role: Optional($0["restartPolicy"].string == "Always" ? "Sidecar" : "Init")) }
        return regular + initial
    }

    @ViewBuilder
    private func dictionarySection(_ title: String, _ values: [String: String]) -> some View {
        if !values.isEmpty {
            Section(title) {
                ForEach(values.sorted { $0.key < $1.key }, id: \.key) { key, value in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key).font(.caption).foregroundStyle(.secondary)
                        Text(value).textSelection(.enabled).lineLimit(4)
                    }
                }
            }
        }
    }
}

/// A container's state and image details: what was asked for (spec) and what is running (status).
private struct ContainerSection: View {
    let pod: KubeObject
    let spec: JSONValue
    let role: String?

    var body: some View {
        let name = spec["name"].string ?? ""
        let statuses = pod.raw["status.containerStatuses"].array + pod.raw["status.initContainerStatuses"].array
        let status = statuses.first { $0["name"].string == name } ?? .null
        let image = spec["image"].string ?? ""
        let ref = ImageReference(image)
        let digest = status["imageID"].string.flatMap(ImageReference.digest(fromImageID:))
        Section {
            LabeledContent("Image") {
                Text(image).font(.callout.monospaced()).textSelection(.enabled).lineLimit(3).multilineTextAlignment(.trailing)
            }
            .contextMenu { menu(image: image, digest: digest, ref: ref) }
            LabeledContent("Registry", value: ref.registryName)
            LabeledContent("Repository", value: ref.repository)
            LabeledContent("Tag") {
                HStack(spacing: 4) {
                    if ref.tag == "latest" {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help("A mutable tag: the running digest tells you which build this is")
                    }
                    Text(ref.tag ?? "pinned by digest").textSelection(.enabled)
                }
            }
            LabeledContent("Running Digest") {
                Text(digest.map(short) ?? "—").font(.callout.monospaced()).textSelection(.enabled)
                    .help(digest ?? "Not reported yet")
            }
            .contextMenu { menu(image: image, digest: digest, ref: ref) }
            if let pinned = ref.digest, let digest, pinned != digest {
                Label("Running digest differs from the pinned one", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            LabeledContent("Pull Policy", value: spec["imagePullPolicy"].string ?? "—")
            if let started = status["state.running.startedAt"].string.flatMap(KubeObject.parseDate) {
                LabeledContent("Started") { Text(started, format: .relative(presentation: .named)) }
            }
            LabeledContent("Restarts", value: String(status["restartCount"].int ?? 0))
            if let reason = status["lastState.terminated.reason"].string {
                LabeledContent("Last Exit", value: "\(reason) (\(status["lastState.terminated.exitCode"].int ?? 0))")
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: status["ready"].bool == true ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(status["ready"].bool == true ? .green : .orange)
                Text(name)
                if let role {
                    Text(role).font(.caption2.weight(.medium)).padding(.horizontal, 5).background(Capsule().fill(.quaternary))
                }
                Spacer()
                Text((status["state"].object.keys.first ?? "unknown").capitalized).foregroundStyle(.secondary)
            }
        }
    }

    private func short(_ digest: String) -> String {
        let parts = digest.split(separator: ":", maxSplits: 1)
        return parts.count == 2 ? "\(parts[0]):\(parts[1].prefix(12))" : digest
    }

    @ViewBuilder
    private func menu(image: String, digest: String?, ref: ImageReference) -> some View {
        Button("Copy Image") { copy(image) }
        if let digest {
            Button("Copy Digest") { copy(digest) }
            Button("Copy Image@Digest") { copy("\(ref.registry)/\(ref.repository)@\(digest)") }
        }
        if let url = ref.webURL { Button("Open in Registry") { NSWorkspace.shared.open(url) } }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
