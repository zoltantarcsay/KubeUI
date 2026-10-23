import AppKit
import KubeKit
import SwiftUI

/// An Argo CD application with its three layers stacked as one delivery pipeline:
/// Source (git) → Argo CD (sync) → Cluster (live pods), and a section per layer below.
struct ApplicationView: View {
    let model: ArgoAppModel
    let close: () -> Void
    @State private var section: Section = initialSection

    enum Section: String, CaseIterable { case values = "Values", changes = "Changes", resources = "Resources" }

    private static var initialSection: Section {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["KUBEUI_APP_SECTION"], let s = Section(rawValue: name) { return s }
        #endif
        return .values
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PipelineView(model: model) { section = $0 }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            Picker("Section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { s in
                    Text(s == .changes && !model.changes.isEmpty ? "Changes (\(model.changes.count))" : s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 8)
            Divider()
            switch section {
            case .values: ValuesView(model: model) { section = .changes }
            case .changes: ChangesView(model: model)
            case .resources: ArgoResourcesView(model: model)
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
        } message: {
            Text(model.alert ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: close) { Label("Applications", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Back to Applications")
            Divider().frame(height: 18)
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.application.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { Task { await model.refreshArgo() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Ask Argo CD to re-read git now")
            Button { Task { await model.syncArgo() } } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                .help("Start an Argo CD sync to the target revision")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        let app = model.application
        var parts = ["→ \(app.destinationNamespace ?? "?")"]
        if let set = app.applicationSet { parts.append("from \(set)") }
        if let source = model.valuesSource { parts.append("\(model.shortRepo(source.repoURL)) @ \(source.targetRevision)") }
        return parts.joined(separator: "  ·  ")
    }
}

/// Three cards joined by arrows; each lights up as a change moves from git to running pods.
private struct PipelineView: View {
    let model: ArgoAppModel
    let select: (ApplicationView.Section) -> Void

    var body: some View {
        HStack(spacing: 6) {
            card("Source", "chevron.left.forwardslash.chevron.right", model.sourceStage) { select(.changes) } accessory: {
                if model.repo == nil, model.repoURL != nil {
                    Button("Link Repository…", action: linkRepository).controlSize(.small)
                }
            }
            arrow
            card("Argo CD", "arrow.triangle.branch", model.argoStage) { select(.values) } accessory: { EmptyView() }
            arrow
            card("Cluster", "server.rack", model.clusterStage) { select(.resources) } accessory: { EmptyView() }
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }

    private func card(_ title: String, _ symbol: String, _ stage: ArgoAppModel.Stage, action: @escaping () -> Void,
                      @ViewBuilder accessory: () -> some View) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                StageIcon(state: stage.state)
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
                    Text(stage.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(stage.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    accessory()
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(stage.state.tint.opacity(stage.state == .idle ? 0.15 : 0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func linkRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link"
        panel.message = "Choose your local clone of \(model.repoURL ?? "the GitOps repository")"
        if panel.runModal() == .OK, let url = panel.url { Task { await model.link(url) } }
    }
}

struct StageIcon: View {
    let state: ArgoAppModel.StageState

    var body: some View {
        Group {
            switch state {
            case .working: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill")
            case .waiting: Image(systemName: "clock.fill")
            case .failed: Image(systemName: "exclamationmark.triangle.fill")
            case .idle: Image(systemName: "circle.dashed")
            }
        }
        .foregroundStyle(state.tint)
        .frame(width: 18, height: 18)
    }
}

extension ArgoAppModel.StageState {
    var tint: Color {
        switch self {
        case .done: .green
        case .waiting: .orange
        case .working: .blue
        case .failed: .red
        case .idle: .secondary
        }
    }
}

/// Argo's sync/health words, coloured the way Argo's UI does.
func argoTint(_ status: String?) -> Color {
    switch status {
    case "Synced", "Healthy", "Succeeded", "Running": .green
    case "OutOfSync", "Progressing", "Pending", "ContainerCreating": .orange
    case "Degraded", "Missing", "Failed", "Error", "CrashLoopBackOff": .red
    default: .secondary
    }
}
