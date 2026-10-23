import AppKit
import KubeKit
import SwiftUI

/// The app's effective env vars across its Helm value layers, editable in the right file.
struct ConfigurationView: View {
    let model: ArgoAppModel
    let showChanges: () -> Void
    @State private var selection: EnvVar.ID?
    @State private var editing: EnvEdit?

    struct EnvEdit: Identifiable {
        let id = UUID()
        var key: String
        var value: String
        var layer: Int
        let isNew: Bool
    }

    var body: some View {
        if model.layers.isEmpty {
            ContentUnavailableView {
                Label(model.repo == nil ? "Repository Not Linked" : "No Helm Values", systemImage: "doc.badge.gearshape")
            } description: {
                Text(model.repo == nil
                     ? "Link your local clone of \(model.repoURL.map(model.shortRepo) ?? "the GitOps repo") (Source card above) to see and edit this app's configuration."
                     : "This application has no Helm source with value files.")
            }
        } else {
            HSplitView {
                envTable.frame(minWidth: 380)
                layerList.frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            }
            .sheet(item: $editing) { edit in
                EnvEditSheet(model: model, edit: edit, showChanges: showChanges) { editing = nil }
            }
        }
    }

    private var envTable: some View {
        VStack(spacing: 0) {
            PanelBar {
                if model.envBlocks.count > 1 {
                    Picker("Block", selection: Binding(get: { model.envBlock ?? [] }, set: { model.envBlock = $0 })) {
                        ForEach(model.envBlocks, id: \.self) { Text($0.joined(separator: ".")).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(model.envBlock?.joined(separator: ".") ?? "env").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { add() } label: { Label("Add Variable", systemImage: "plus") }
                    .help("Add an env var")
                Button { if let v = selected { edit(v) } } label: { Label("Edit", systemImage: "pencil") }
                    .disabled(selected == nil)
                    .help("Edit the selected env var")
            }
            Divider()
            Table(model.env, selection: $selection) {
                TableColumn("Name") { v in
                    Text(v.key).font(.body.monospaced()).fontWeight(v.layer == pinnedIndex(v) ? .regular : .medium)
                }
                .width(min: 120, ideal: 220)
                TableColumn("Value") { v in
                    Text(v.value).font(.body.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .width(min: 120, ideal: 240)
                TableColumn("Set In") { v in
                    HStack(spacing: 4) {
                        if case .inline = model.layers[v.layer].origin { Image(systemName: "lock.fill").foregroundStyle(.orange) }
                        Text(layerName(v.layer)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        if v.definedIn.count > 1 {
                            Text("overrides \(v.definedIn.count - 1)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .help(v.definedIn.map(layerName).joined(separator: " → "))
                }
            }
            .contextMenu(forSelectionType: EnvVar.ID.self) { ids in
                if let v = model.env.first(where: { ids.contains($0.id) }) {
                    Button("Edit…") { edit(v) }
                    if let layer = removableLayer(v) {
                        Button("Remove from \(layerName(layer))") { model.removeEnv(v.key, layer: layer) }
                    }
                    Button("Copy Value") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(v.value, forType: .string)
                    }
                }
            } primaryAction: { ids in
                if let v = model.env.first(where: { ids.contains($0.id) }) { edit(v) }
            }
        }
    }

    private var layerList: some View {
        List {
            Section("Value layers (later wins)") {
                ForEach(Array(model.layers.enumerated()), id: \.offset) { i, layer in
                    HStack(spacing: 6) {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 14)
                        Image(systemName: icon(layer)).foregroundStyle(layer.exists ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(layerName(i)).lineLimit(1).truncationMode(.head)
                            Text(caption(layer)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .help(layer.title)
                    .contextMenu {
                        if let file = layer.file, layer.exists {
                            Button("Open in Default Editor") { NSWorkspace.shared.open(file) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(layer.title, forType: .string)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var selected: EnvVar? { model.env.first { $0.id == selection } }

    private func pinnedIndex(_ v: EnvVar) -> Int? {
        if case .inline = model.layers[v.layer].origin { return v.layer }
        return nil
    }

    private func removableLayer(_ v: EnvVar) -> Int? {
        model.layers[v.layer].isEditable ? v.layer : nil
    }

    private func layerName(_ i: Int) -> String {
        let layer = model.layers[i]
        if case .inline(let owner) = layer.origin { return owner }
        return layer.title
    }

    private func icon(_ layer: ValueLayer) -> String {
        switch layer.origin {
        case .chartDefaults: "shippingbox"
        case .valueFile: layer.exists ? "doc.text" : "doc.badge.plus"
        case .inline: "lock"
        }
    }

    private func caption(_ layer: ValueLayer) -> String {
        switch layer.origin {
        case .chartDefaults: "Chart defaults"
        case .valueFile: layer.exists ? "Values file" : "Doesn't exist yet; created on first edit"
        case .inline: "Inline values, can't be overridden by files"
        }
    }

    private func add() {
        guard let layer = HelmValues.targetLayer(for: "", block: model.envBlock ?? [], in: model.layers) else { return }
        editing = EnvEdit(key: "", value: "", layer: layer, isNew: true)
    }

    private func edit(_ v: EnvVar) {
        let layer = HelmValues.targetLayer(for: v.key, block: model.envBlock ?? [], in: model.layers) ?? v.layer
        editing = EnvEdit(key: v.key, value: v.value, layer: layer, isNew: false)
    }
}

private struct EnvEditSheet: View {
    let model: ArgoAppModel
    @State var edit: ConfigurationView.EnvEdit
    let showChanges: () -> Void
    let dismiss: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $edit.key).disabled(!edit.isNew).font(.body.monospaced())
                TextField("Value", text: $edit.value, axis: .vertical).font(.body.monospaced()).lineLimit(1...6)
                Picker("Write to", selection: $edit.layer) {
                    ForEach(editableLayers, id: \.self) { i in Text(model.layers[i].title).tag(i) }
                }
            } footer: {
                Text(impact).font(.callout).foregroundStyle(pinned != nil ? .red : .secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.setEnv(edit.key.trimmingCharacters(in: .whitespaces), value: edit.value, layer: edit.layer)
                    dismiss()
                    showChanges()
                }
                .disabled(edit.key.trimmingCharacters(in: .whitespaces).isEmpty || pinned != nil)
            }
        }
    }

    private var editableLayers: [Int] {
        model.layers.indices.filter { model.layers[$0].isEditable }
    }

    private var pinned: ValueLayer? {
        HelmValues.pinnedInline(edit.key, block: model.envBlock ?? [], in: model.layers)
    }

    private var impact: String {
        if let pinned { return "\(edit.key) is set inline by the \(pinned.title.replacingOccurrences(of: "Inline values ", with: "")), which overrides every values file. Change it there instead." }
        let layer = model.layers[edit.layer]
        let laterSetters = model.layers.indices.filter { $0 > edit.layer && YAMLEdit(model.layers[$0].text).entries(model.envBlock ?? []).contains { $0.key == edit.key } }
        if let shadow = laterSetters.last {
            return "A later layer (\(model.layers[shadow].title)) also sets \(edit.key), so this edit won't take effect."
        }
        let first = model.layers.firstIndex { $0.origin == .valueFile }
        if edit.layer == first || layer.origin == .chartDefaults {
            return "\(layer.title) is shared: this changes every tenant and environment that uses it."
        }
        return "Saved to \(layer.title)\(layer.exists ? "" : " (new file)"). Review the diff under Changes, then commit and push."
    }
}
