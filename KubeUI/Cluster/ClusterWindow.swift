import KubeKit
import SwiftUI

struct ClusterWindow: View {
    @Environment(AppModel.self) private var app
    @State private var model = ClusterModel()
    @State private var showInspector = DebugHooks.showsInspector
    @State private var typedNamespace: String?
    @SceneStorage("context") private var savedContext: String?
    @SceneStorage("kind") private var savedKind: String?
    @AppStorage("panelHeight") private var panelHeight = 300.0

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    if let focused = model.focusedApp {
                        ApplicationView(model: focused, close: model.closeApplication)
                            .id(focused.application.id)
                    } else {
                        ResourceTable(model: model)
                    }
                    if model.isPanelVisible, !model.panels.isEmpty {
                        let height = min(max(panelHeight, 140), max(140, geo.size.height - 120))
                        PanelArea(model: model)
                            .frame(height: height)
                            .overlay(alignment: .top) {
                                PanelResizeHandle(height: $panelHeight, current: height, maxHeight: geo.size.height - 120)
                            }
                    }
                }
            }
            .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
        }
        .navigationTitle(model.focusedApp?.application.name ?? model.kind.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $model.search, placement: .toolbar, prompt: "Filter by name")
        .toolbar { toolbar }
        .task {
            if let savedKind, let kind = ResourceKind.kind(id: savedKind) { model.kind = kind }
            await model.start(app: app, preferredContext: savedContext)
        }
        .onChange(of: model.context) { savedContext = model.context }
        .onChange(of: model.kind) { savedKind = model.kind.id }
        .onDisappear { model.stop() }
        .alert("Namespace", isPresented: Binding(get: { typedNamespace != nil }, set: { if !$0 { typedNamespace = nil } })) {
            TextField("Namespace", text: Binding(get: { typedNamespace ?? "" }, set: { typedNamespace = $0 }))
            Button("Show") {
                let ns = typedNamespace?.trimmingCharacters(in: .whitespaces) ?? ""
                model.select(namespace: ns.isEmpty ? nil : ns)
            }
            Button("Cancel", role: .cancel) {}
        }
        .debugHooks(model)
    }

    private var subtitle: String {
        guard let context = model.context else { return "" }
        let ns = model.kind.namespaced ? (model.namespace ?? "All Namespaces") : "Cluster"
        return "\(shortContextName(context)) — \(ns)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Picker("Context", selection: Binding(
                    get: { model.context ?? "" },
                    set: { name in Task { await model.switchContext(name, app: app) } }
                )) {
                    ForEach(model.contexts) { ctx in
                        Text(shortContextName(ctx.name)).tag(ctx.name).help(ctx.name)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.context.map(shortContextName) ?? "Context", systemImage: "point.3.connected.trianglepath.dotted")
                    .labelStyle(.titleAndIcon)
            }
            .help("Kubeconfig context")
        }
        ToolbarItem(placement: .navigation) {
            Menu {
                Picker("Namespace", selection: Binding(
                    get: { model.namespace ?? "" },
                    set: { model.select(namespace: $0.isEmpty ? nil : $0) }
                )) {
                    Text("All Namespaces").tag("")
                    Divider()
                    ForEach(namespaceChoices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                // Needed when RBAC forbids listing namespaces.
                Button("Other Namespace…") { typedNamespace = model.namespace ?? "" }
            } label: {
                Label(model.namespace ?? "All Namespaces", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.kind.namespaced)
            .help("Namespace")
        }
        ToolbarItem {
            Button {
                model.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Reload")
        }
        ToolbarItem {
            Button {
                model.isPanelVisible.toggle()
            } label: {
                Label("Panel", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(model.panels.isEmpty)
            .help("Show or hide the logs and files panel")
        }
        ToolbarItem {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Show or hide the inspector")
        }
    }

    private var namespaceChoices: [String] {
        var list = model.namespaces
        if let current = model.namespace, !list.contains(current) { list.insert(current, at: 0) }
        return list
    }
}

/// EKS context names are long ARNs; show just the cluster name.
func shortContextName(_ name: String) -> String {
    if name.hasPrefix("arn:aws:eks:"), let slash = name.lastIndex(of: "/") {
        return String(name[name.index(after: slash)...])
    }
    return name
}

private struct Sidebar: View {
    @Bindable var model: ClusterModel

    var body: some View {
        List(selection: Binding(get: { model.kind }, set: { if let k = $0 { model.select(kind: k) } })) {
            ForEach(ResourceKind.Section.allCases.filter { $0 != .argocd || model.argoAvailable }, id: \.self) { section in
                Section(section.rawValue) {
                    ForEach(ResourceKind.all.filter { $0.section == section }) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Drag target on the panel's top edge, like the divider above Xcode's debug area.
private struct PanelResizeHandle: View {
    @Binding var height: Double
    let current: Double
    let maxHeight: Double
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(height: 6)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .top))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = start ?? current
                        start = base
                        height = min(max(base - value.translation.height, 140), maxHeight)
                    }
                    .onEnded { _ in start = nil }
            )
    }
}

