import AppKit
import KubeKit
import SwiftUI

/// The app's Helm values merged across all layers, whatever their structure: every key shows the
/// layer that wins it and can be edited there; any layer opens as a file for free-form edits.
struct ValuesView: View {
    let model: ArgoAppModel
    let showChanges: () -> Void
    @State private var selection: ValueNode.ID?
    @State private var search = DebugHooks.valuesSearch
    @State private var editing: ValueEdit?

    struct ValueEdit: Identifiable {
        let id = UUID()
        /// Parent mapping of the key being edited or added.
        let parent: [String]
        var key: String
        var value: String
        var layer: Int
        let previousRaw: String?
        let isNew: Bool
    }

    var body: some View {
        if model.layers.isEmpty {
            ContentUnavailableView {
                Label(model.repo == nil ? "Repository Not Linked" : "No Helm Values", systemImage: "doc.badge.gearshape")
            } description: {
                Text(model.repo == nil
                     ? "Link your local clone of \(model.repoURL.map(model.shortRepo) ?? "the GitOps repo") (Source card above) to see and edit this app's values."
                     : "This application has no Helm source with values.")
            }
        } else {
            HSplitView {
                valuesTable.frame(minWidth: 420)
                layerList.frame(minWidth: 240, idealWidth: 300, maxWidth: 440)
            }
            .sheet(item: $editing) { edit in
                ValueEditSheet(model: model, edit: edit, showChanges: showChanges) { editing = nil }
            }
        }
    }

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The tree, or a flat list of matching keys (path or value) while searching.
    private var rows: [ValueNode] {
        guard isSearching else { return model.tree }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return HelmValues.flatten(model.tree)
            .filter { $0.kind != .mapping && ($0.dottedPath.lowercased().contains(q) || $0.value.lowercased().contains(q)) }
            .map { var n = $0; n.children = nil; return n }
    }

    private var selected: ValueNode? {
        HelmValues.flatten(model.tree).first { $0.id == selection }
    }

    private var valuesTable: some View {
        VStack(spacing: 0) {
            PanelBar {
                TextField("Search keys and values", text: $search, prompt: Text("Search keys and values"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button { add(under: selected) } label: { Label("Add Key", systemImage: "plus") }
                    .help(addHelp)
                Button { if let n = selected { edit(n) } } label: { Label("Edit", systemImage: "pencil") }
                    .disabled(selected == nil || selected?.kind == .mapping)
                    .help("Edit the selected value")
                Button { if let n = selected { model.openLayer(n.layer) } } label: { Label("Open Layer", systemImage: "doc.text") }
                    .disabled(selected == nil)
                    .help("Open the file that sets the selected value")
            }
            Divider()
            Table(rows, children: \.children, selection: $selection) {
                TableColumn("Key") { n in
                    Label {
                        Text(isSearching ? n.dottedPath : n.key).font(.body.monospaced()).lineLimit(1).truncationMode(.head)
                    } icon: {
                        Image(systemName: icon(n)).foregroundStyle(.secondary)
                    }
                    .help(n.dottedPath)
                }
                .width(min: 160, ideal: 280)
                TableColumn("Value") { n in
                    Text(display(n))
                        .font(.body.monospaced())
                        .foregroundStyle(n.kind == .scalar ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .width(min: 100, ideal: 220)
                TableColumn("Set In") { n in
                    if n.kind == .mapping {
                        Text("merged from \(n.definedIn.count) layer\(n.definedIn.count == 1 ? "" : "s")")
                            .foregroundStyle(.tertiary)
                            .help(n.definedIn.map(layerName).joined(separator: " + "))
                    } else {
                    HStack(spacing: 4) {
                        if case .inline? = model.layers[safe: n.layer]?.origin { Image(systemName: "lock.fill").foregroundStyle(.orange) }
                        Text(layerName(n.layer)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        if n.kind != .mapping, n.definedIn.count > 1 {
                            Text("overrides \(n.definedIn.count - 1)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .help(n.definedIn.map(layerName).joined(separator: " → "))
                    }
                }
            }
            .contextMenu(forSelectionType: ValueNode.ID.self) { ids in
                if let n = HelmValues.flatten(model.tree).first(where: { ids.contains($0.id) }) { menu(n) }
            } primaryAction: { ids in
                guard let n = HelmValues.flatten(model.tree).first(where: { ids.contains($0.id) }) else { return }
                n.kind == .mapping ? add(under: n) : edit(n)
            }
        }
    }

    @ViewBuilder
    private func menu(_ n: ValueNode) -> some View {
        if n.kind != .mapping { Button("Edit…") { edit(n) } }
        if n.kind == .mapping { Button("Add Key Here…") { add(under: n) } }
        Button("Open \(layerName(n.layer))") { model.openLayer(n.layer) }
        if model.layers[safe: n.layer]?.isEditable == true {
            Button("Remove from \(layerName(n.layer))") { model.removeValue(n.path, layer: n.layer) }
        }
        Divider()
        Button("Copy Path") { copy(n.dottedPath) }
        if n.kind == .scalar { Button("Copy Value") { copy(n.value) } }
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
                    .help("\(layer.title)\nDouble-click to open")
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.openLayer(i) }
                    .contextMenu {
                        Button(layer.isEditable ? "Open in Editor" : "View") { model.openLayer(i) }
                        if let file = layer.file, layer.exists {
                            Button("Open in Default Editor") { NSWorkspace.shared.open(file) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        }
                        Button("Copy Path") { copy(layer.title) }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var addHelp: String {
        guard let n = selected else { return "Add a top-level key" }
        return "Add a key under \(n.kind == .mapping ? n.dottedPath : n.path.dropLast().joined(separator: "."))"
    }

    private func display(_ n: ValueNode) -> String {
        switch n.kind {
        case .mapping: "{\(n.children?.count ?? 0) keys}"
        case .list: n.value
        case .scalar: n.value.replacingOccurrences(of: "\n", with: "⏎ ")
        }
    }

    private func icon(_ n: ValueNode) -> String {
        switch n.kind {
        case .mapping: "curlybraces"
        case .list: "list.bullet"
        case .scalar: "equal"
        }
    }

    private func layerName(_ i: Int) -> String {
        guard let layer = model.layers[safe: i] else { return "?" }
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

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func add(under node: ValueNode?) {
        let parent = node.map { $0.kind == .mapping ? $0.path : Array($0.path.dropLast()) } ?? []
        let layer = HelmValues.targetLayer(for: parent + ["\u{0}"], in: model.layers) ?? model.layers.lastIndex { $0.isEditable } ?? 0
        editing = ValueEdit(parent: parent, key: "", value: "", layer: layer, previousRaw: nil, isNew: true)
    }

    private func edit(_ n: ValueNode) {
        let layer = HelmValues.targetLayer(for: n.path, in: model.layers) ?? n.layer
        let value = n.kind == .scalar && !(n.rawValue.hasPrefix("|") || n.rawValue.hasPrefix(">")) ? n.value : ""
        editing = ValueEdit(parent: Array(n.path.dropLast()), key: n.key, value: value, layer: layer, previousRaw: n.rawValue, isNew: false)
    }
}

private struct ValueEditSheet: View {
    let model: ArgoAppModel
    @State var edit: ValuesView.ValueEdit
    let showChanges: () -> Void
    let dismiss: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Path") {
                    Text(path.joined(separator: ".")).font(.body.monospaced()).textSelection(.enabled)
                }
                if edit.isNew { TextField("Key", text: $edit.key).font(.body.monospaced()) }
                if isComplex {
                    LabeledContent("Value") {
                        Text("A list or multi-line value: edit it in the file.").foregroundStyle(.secondary)
                    }
                } else {
                    TextField("Value", text: $edit.value, prompt: Text("e.g. 3, true, text or \"quoted\"")).font(.body.monospaced())
                }
                Picker("Write to", selection: $edit.layer) {
                    ForEach(model.layers.indices.filter { model.layers[$0].isEditable }, id: \.self) { i in Text(model.layers[i].title).tag(i) }
                }
            } footer: {
                Text(impact).font(.callout).foregroundStyle(pinned != nil ? .red : .secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) }
            if isComplex {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open File") {
                        model.openLayer(edit.layer)
                        dismiss()
                    }
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.setValue(path, literal: YAMLEdit.literal(from: edit.value, previous: edit.previousRaw), layer: edit.layer)
                        dismiss()
                        showChanges()
                    }
                    .disabled(key.isEmpty || pinned != nil)
                }
            }
        }
    }

    private var key: String { edit.key.trimmingCharacters(in: .whitespaces) }
    private var path: [String] { edit.parent + (key.isEmpty ? [] : [key]) }

    /// Lists, nested mappings and block scalars are edited in the raw file, not here.
    private var isComplex: Bool {
        guard let raw = edit.previousRaw, !edit.isNew else { return false }
        let node = HelmValues.flatten(model.tree).first { $0.path == path }
        return node?.kind != .scalar || raw.hasPrefix("|") || raw.hasPrefix(">")
    }

    private var pinned: ValueLayer? {
        key.isEmpty ? nil : HelmValues.pinnedInline(path, in: model.layers)
    }

    private var impact: String {
        if let pinned {
            return "\(path.joined(separator: ".")) is set inline by the \(pinned.title.replacingOccurrences(of: "Inline values ", with: "")), which overrides every values file. Change it there instead."
        }
        guard let layer = model.layers[safe: edit.layer] else { return "" }
        if let shadow = model.layers.indices.last(where: { $0 > edit.layer && YAMLEdit(model.layers[$0].text).entry(path) != nil }) {
            return "A later layer (\(model.layers[shadow].title)) also sets this, so the edit won't take effect."
        }
        if edit.layer == model.layers.firstIndex(where: { $0.origin == .valueFile }) || layer.origin == .chartDefaults {
            return "\(layer.title) is shared: this changes every tenant and environment that uses it."
        }
        return "Saved to \(layer.title)\(layer.exists ? "" : " (new file)"). Typed values are written as YAML: 3 and true stay a number and a boolean; quote them to make strings."
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
