import KubeKit
import SwiftUI

struct LogsWindow: View {
    let pod: PodRef
    @Environment(AppModel.self) private var app
    @State private var container: String?
    @State private var follow = true
    @State private var previous = false
    @State private var wrap = false
    @State private var tail = 500
    @State private var controller = TextViewController()
    @State private var error: String?
    @State private var streaming = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        MonospaceTextView(controller: controller)
            .overlay(alignment: .bottom) {
                if let error {
                    Text(error)
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.red.opacity(0.15))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Logs — \(pod.pod)")
            .navigationSubtitle([container, pod.namespace].compactMap { $0 }.joined(separator: " · "))
            .toolbar {
                if pod.containers.count > 1 {
                    ToolbarItem {
                        Picker("Container", selection: Binding(get: { container ?? "" }, set: { container = $0; restart() })) {
                            ForEach(pod.containers, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                ToolbarItem {
                    Picker("Lines", selection: Binding(get: { tail }, set: { tail = $0; restart() })) {
                        ForEach([100, 500, 2000, 10000], id: \.self) { Text("Last \($0) lines").tag($0) }
                        Text("All lines").tag(-1)
                    }
                }
                ToolbarItemGroup {
                    Toggle(isOn: Binding(get: { follow }, set: { follow = $0; restart() })) {
                        Label("Follow", systemImage: streaming ? "dot.radiowaves.left.and.right" : "pause.circle")
                    }
                    .help("Stream new log lines")
                    Toggle(isOn: Binding(get: { previous }, set: { previous = $0; restart() })) {
                        Label("Previous", systemImage: "arrow.uturn.backward.circle")
                    }
                    .help("Show logs of the previous (crashed) container instance")
                    Toggle(isOn: Binding(get: { wrap }, set: { wrap = $0; controller.setWraps($0) })) {
                        Label("Wrap", systemImage: "text.word.spacing")
                    }
                    .help("Wrap long lines")
                    Button { controller.clear() } label: { Label("Clear", systemImage: "trash") }
                        .keyboardShortcut("k")
                        .help("Clear")
                    Button { restart() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r")
                        .help("Reload")
                }
            }
            .onAppear {
                controller.lineStyler = LogHighlighter.style
                container = pod.containers.first
                restart()
            }
            .onDisappear { task?.cancel() }
    }

    private func restart() {
        task?.cancel()
        controller.clear()
        error = nil
        let follow = follow && !previous
        task = Task {
            guard let client = await app.client(context: pod.context) else {
                error = app.setupError
                return
            }
            streaming = follow
            defer { if !Task.isCancelled { streaming = false } }
            do {
                for try await chunk in client.logs(pod: pod.pod, namespace: pod.namespace, container: container, tail: tail, follow: follow, previous: previous) {
                    controller.append(String(decoding: chunk, as: UTF8.self))
                }
                controller.flush()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
