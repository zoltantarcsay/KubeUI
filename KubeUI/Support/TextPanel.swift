import KubeKit
import SwiftUI

/// Read-only YAML or `kubectl describe` output, with the standard find bar (⌘F).
@Observable
final class TextModel {
    let target: TextTarget
    let controller = TextViewController()
    private(set) var error: String?
    private var app: AppModel?

    init(target: TextTarget) {
        self.target = target
    }

    func start(app: AppModel) {
        self.app = app
        Task { await load() }
    }

    func load() async {
        guard let kind = ResourceKind.kind(id: target.kindID), let client = await app?.client(context: target.context) else {
            error = app?.setupError ?? "Unknown resource kind"
            return
        }
        do {
            let text = switch target.mode {
            case .yaml: try await client.yaml(kind, name: target.name, namespace: target.namespace)
            case .describe: try await client.describe(kind, name: target.name, namespace: target.namespace)
            }
            error = nil
            controller.setText(text)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TextPanel: View {
    let model: TextModel

    var body: some View {
        VStack(spacing: 0) {
            MonospaceTextView(controller: model.controller)
                .overlay {
                    if let error = model.error {
                        ContentUnavailableView("Can't Load", systemImage: "exclamationmark.triangle", description: Text(error))
                            .background(.background)
                    }
                }
            Divider()
            PanelBar {
                Text("\(model.target.kindID) · \(model.target.namespace ?? shortContextName(model.target.context))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.controller.textView.string, forType: .string)
                } label: { Label("Copy All", systemImage: "doc.on.doc") }
                    .help("Copy all")
                Button { Task { await model.load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Reload")
            }
        }
    }
}
