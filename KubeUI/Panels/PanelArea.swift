import KubeKit
import SwiftUI

/// A view opened in the bottom panel. Its model outlives tab switches, so logs keep streaming.
@Observable
final class PanelTab: Identifiable {
    enum Content {
        case files(PodFilesModel)
        case logs(LogsModel)
        case text(TextModel)
        case editor(FileEditorModel)
        case shell(ShellModel)
        case diff(ArgoAppModel)
    }

    enum Request {
        case files(PodRef)
        case logs(PodRef)
        case text(TextTarget)
        case editor(FileEditorModel)
        case shell(PodRef, container: String?)
        case diff(ArgoAppModel)

        var id: String {
            switch self {
            case .files(let p): "files:\(p.context)/\(p.namespace)/\(p.pod)"
            case .logs(let p): "logs:\(p.context)/\(p.namespace)/\(p.pod)"
            case .text(let t): "\(t.mode.rawValue):\(t.context)/\(t.namespace ?? "")/\(t.kindID)/\(t.name)"
            case .editor(let e): e.id
            case .shell(let p, let c): "shell:\(p.context)/\(p.namespace)/\(p.pod)/\(c ?? "")"
            case .diff(let a): "diff:\(a.context)/\(a.application.namespace)/\(a.application.name)"
            }
        }
    }

    let id: String
    let title: String
    let help: String
    let symbol: String
    let content: Content

    init(_ request: Request, app: AppModel) {
        id = request.id
        switch request {
        case .files(let pod):
            let model = PodFilesModel(pod: pod)
            Task { await model.start(app: app) }
            content = .files(model)
            title = pod.pod
            help = "Files — \(pod.pod) in \(pod.namespace) (\(shortContextName(pod.context)))"
            symbol = "folder"
        case .logs(let pod):
            let model = LogsModel(pod: pod)
            model.start(app: app)
            content = .logs(model)
            title = pod.pod
            help = "Logs — \(pod.pod) in \(pod.namespace) (\(shortContextName(pod.context)))"
            symbol = "text.alignleft"
        case .text(let target):
            let model = TextModel(target: target)
            model.start(app: app)
            content = .text(model)
            title = target.name
            help = "\(target.mode == .yaml ? "YAML" : "Describe") — \(target.kindID)/\(target.name)"
            symbol = target.mode == .yaml ? "curlybraces" : "doc.text.magnifyingglass"
        case .editor(let editor):
            content = .editor(editor)
            title = (editor.title as NSString).lastPathComponent
            help = editor.title
            symbol = editor.file == nil ? "lock.doc" : "doc.text"
        case .shell(let pod, let container):
            let shell = ShellModel(pod: pod, container: container)
            shell.start(app: app)
            content = .shell(shell)
            title = pod.containers.count > 1 ? "\(pod.pod) (\(shell.container ?? ""))" : pod.pod
            help = "Shell — \(pod.pod) in \(pod.namespace) (\(shortContextName(pod.context)))"
            symbol = "terminal"
        case .diff(let argo):
            content = .diff(argo)
            title = argo.application.name
            help = "Uncommitted changes — \(argo.application.name)"
            symbol = "plus.forwardslash.minus"
        }
    }

    func stop() {
        switch content {
        case .files(let model): model.stop()
        case .logs(let model): model.stop()
        case .shell(let model): model.stop()
        case .text, .editor, .diff: break
        }
    }
}

/// One side-by-side pane of the bottom panel with its own tabs, like an editor group in VS Code.
struct PanelSplit: Identifiable {
    let id = UUID()
    var tabIDs: [String]
    var activeID: String
}

/// Compact bar for panel controls, sized like Xcode's debug bar.
struct PanelBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .buttonStyle(.borderless)
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(.bar)
    }
}

/// The bottom area of a cluster window, like Xcode's debug area: tabs for opened logs, files and YAML.
struct PanelArea: View {
    let model: ClusterModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HSplitView {
                ForEach(model.panelSplits) { split in
                    VStack(spacing: 0) {
                        tabStrip(split)
                        Divider()
                        if let tab = model.panels.first(where: { $0.id == split.activeID }) {
                            content(tab).id(tab.id)
                        } else {
                            Spacer()
                        }
                    }
                    .frame(minWidth: 240, maxWidth: .infinity)
                }
            }
            // A fresh split view shares the width evenly; the old one keeps stale pane sizes.
            .id(model.panelSplits.map(\.id))
        }
    }

    private func tabStrip(_ split: PanelSplit) -> some View {
        let index = model.panelSplits.firstIndex { $0.id == split.id } ?? 0
        return HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(split.tabIDs, id: \.self) { id in
                        if let tab = model.panels.first(where: { $0.id == id }) {
                            PanelTabButton(tab: tab, isActive: id == split.activeID,
                                           select: { model.selectPanel(id) },
                                           close: { model.closePanel(id) }) {
                                Button("Split Right") { model.splitPanelRight(id) }
                                    .disabled(!model.canSplitPanel(id))
                                if index > 0 {
                                    Button("Move to Left Split") { model.movePanel(id, by: -1) }
                                }
                                if index < model.panelSplits.count - 1 {
                                    Button("Move to Right Split") { model.movePanel(id, by: 1) }
                                }
                                Divider()
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            if index == model.panelSplits.count - 1 {
                Button { model.isPanelVisible = false } label: { Label("Hide Panel", systemImage: "chevron.down") }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("Hide the panel (⇧⌘Y)")
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: 30)
        .background(.bar)
    }

    @ViewBuilder
    private func content(_ tab: PanelTab) -> some View {
        switch tab.content {
        case .files(let files): PodFilesPanel(model: files)
        case .logs(let logs): LogsPanel(model: logs)
        case .text(let text): TextPanel(model: text)
        case .editor(let editor): FileEditorPanel(model: editor)
        case .shell(let shell): ShellPanel(model: shell)
        case .diff(let argo): DiffPanel(model: argo)
        }
    }
}

private struct PanelTabButton<Actions: View>: View {
    let tab: PanelTab
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @ViewBuilder let actions: Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.symbol)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .leading)
            Button(action: close) { Image(systemName: "xmark").font(.caption2.weight(.semibold)) }
                .buttonStyle(.borderless)
                .opacity(hovering || isActive ? 1 : 0)
                .help("Close tab")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isActive ? Color.primary.opacity(0.09) : (hovering ? Color.primary.opacity(0.04) : .clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(tab.help)
        .contextMenu {
            actions
            Button("Close Tab", action: close)
        }
    }
}
