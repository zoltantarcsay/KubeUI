import KubeKit
import SwiftUI

/// Read-only YAML or `kubectl describe` output, with the standard find bar (⌘F).
struct TextWindow: View {
    let target: TextTarget
    @Environment(AppModel.self) private var app
    @State private var controller = TextViewController()
    @State private var error: String?

    var body: some View {
        MonospaceTextView(controller: controller)
            .overlay {
                if let error {
                    ContentUnavailableView("Can't Load", systemImage: "exclamationmark.triangle", description: Text(error))
                        .background(.background)
                }
            }
            .navigationTitle(target.name)
            .navigationSubtitle("\(target.mode == .yaml ? "YAML" : "Describe") · \(target.namespace ?? shortContextName(target.context))")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.textView.string, forType: .string)
                    } label: { Label("Copy All", systemImage: "doc.on.doc") }
                        .help("Copy all")
                    Button { Task { await load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r")
                        .help("Reload")
                }
            }
            .task { await load() }
    }

    private func load() async {
        guard let kind = ResourceKind.kind(id: target.kindID), let client = await app.client(context: target.context) else {
            error = app.setupError ?? "Unknown resource kind"
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
