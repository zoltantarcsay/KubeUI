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
    }

    enum Request {
        case files(PodRef)
        case logs(PodRef)
        case text(TextTarget)
        case editor(FileEditorModel)

        var id: String {
            switch self {
            case .files(let p): "files:\(p.context)/\(p.namespace)/\(p.pod)"
            case .logs(let p): "logs:\(p.context)/\(p.namespace)/\(p.pod)"
            case .text(let t): "\(t.mode.rawValue):\(t.context)/\(t.namespace ?? "")/\(t.kindID)/\(t.name)"
            case .editor(let e): e.id
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
        }
    }

    func stop() {
        switch content {
        case .files(let model): model.stop()
        case .logs(let model): model.stop()
        case .text, .editor: break
        }
    }
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
            tabStrip
            Divider()
            if let tab = model.activePanel {
                content(tab).id(tab.id)
            } else {
                Spacer()
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.panels) { tab in
                        PanelTabButton(tab: tab, isActive: tab.id == model.activePanelID,
                                       select: { model.activePanelID = tab.id },
                                       close: { model.closePanel(tab.id) })
                    }
                }
                .padding(.horizontal, 6)
            }
            Button { model.isPanelVisible = false } label: { Label("Hide Panel", systemImage: "chevron.down") }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Hide the panel (⇧⌘Y)")
                .padding(.horizontal, 8)
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
        }
    }
}

private struct PanelTabButton: View {
    let tab: PanelTab
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
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
            Button("Close Tab", action: close)
        }
    }
}
