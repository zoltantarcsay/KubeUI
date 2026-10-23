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
                    Section("Containers") {
                        ForEach(object.raw["spec.containers"].array.indices, id: \.self) { i in
                            container(object, index: i)
                        }
                    }
                    Section {
                        LabeledContent("Node", value: object.raw["spec.nodeName"].string ?? "—")
                        LabeledContent("Pod IP", value: object.raw["status.podIP"].string ?? "—")
                        LabeledContent("QoS", value: object.raw["status.qosClass"].string ?? "—")
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

    private func container(_ pod: KubeObject, index: Int) -> some View {
        let spec = pod.raw["spec.containers"][index]
        let name = spec["name"].string ?? ""
        let status = pod.raw["status.containerStatuses"].array.first { $0["name"].string == name } ?? .null
        let state = status["state"].object.keys.first ?? "unknown"
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: status["ready"].bool == true ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(status["ready"].bool == true ? .green : .orange)
                Text(name).bold()
                Spacer()
                Text(state.capitalized).foregroundStyle(.secondary)
            }
            Text(spec["image"].string ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
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
