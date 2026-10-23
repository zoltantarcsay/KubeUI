import KubeKit
import SwiftUI

/// A streaming `kubectl logs` session; lives as long as its panel tab, so switching tabs keeps it running.
@Observable
final class LogsModel {
    let pod: PodRef
    var container: String?
    var follow = true
    var previous = false
    var wrap = false
    var tail = 500
    var filter = "" { didSet { if filter != oldValue { redisplay() } } }
    let controller = TextViewController()
    private(set) var error: String?
    private(set) var streaming = false
    private var app: AppModel?
    private var task: Task<Void, Never>?
    private var lines: [String] = []
    private var partial = ""
    private let maxLines = 100_000

    init(pod: PodRef) {
        self.pod = pod
        container = pod.containers.first
        controller.lineStyler = LogHighlighter.style
    }

    func start(app: AppModel) {
        self.app = app
        restart()
    }

    func restart() {
        task?.cancel()
        lines = []
        partial = ""
        controller.clear()
        error = nil
        let follow = follow && !previous
        task = Task {
            guard let client = await app?.client(context: pod.context) else {
                error = app?.setupError
                return
            }
            streaming = follow
            defer { if !Task.isCancelled { streaming = false } }
            do {
                for try await chunk in client.logs(pod: pod.pod, namespace: pod.namespace, container: container, tail: tail, follow: follow, previous: previous) {
                    receive(String(decoding: chunk, as: UTF8.self))
                }
                if !partial.isEmpty { receive("\n") }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func stop() { task?.cancel() }

    func clear() {
        lines = []
        controller.clear()
    }

    private func receive(_ text: String) {
        var complete = (partial + text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        partial = complete.removeLast()
        guard !complete.isEmpty else { return }
        lines.append(contentsOf: complete)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        show(complete)
    }

    private func redisplay() {
        controller.clear()
        show(lines)
    }

    private func show(_ batch: [String]) {
        let shown = filter.isEmpty ? batch : batch.filter { $0.localizedCaseInsensitiveContains(filter) }
        if !shown.isEmpty { controller.append(shown.joined(separator: "\n") + "\n") }
    }
}

struct LogsPanel: View {
    let model: LogsModel

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            MonospaceTextView(controller: model.controller)
                .overlay(alignment: .top) {
                    if let error = model.error {
                        Text(error)
                            .font(.callout)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(.red.opacity(0.15))
                            .textSelection(.enabled)
                    }
                }
            Divider()
            // Like Xcode's console: filter on the left, output options on the right.
            PanelBar {
                TextField("Filter", text: $model.filter, prompt: Text("Filter"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                if model.pod.containers.count > 1 {
                    Picker("Container", selection: Binding(get: { model.container ?? "" }, set: { model.container = $0; model.restart() })) {
                        ForEach(model.pod.containers, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Container")
                }
                Picker("Lines", selection: Binding(get: { model.tail }, set: { model.tail = $0; model.restart() })) {
                    ForEach([100, 500, 2000, 10000], id: \.self) { Text("Last \($0) lines").tag($0) }
                    Text("All lines").tag(-1)
                }
                .labelsHidden()
                .fixedSize()
                Toggle(isOn: Binding(get: { model.follow }, set: { model.follow = $0; model.restart() })) {
                    Label("Follow", systemImage: model.streaming ? "dot.radiowaves.left.and.right" : "pause.circle")
                }
                .help("Stream new log lines")
                Toggle(isOn: Binding(get: { model.previous }, set: { model.previous = $0; model.restart() })) {
                    Label("Previous", systemImage: "arrow.uturn.backward.circle")
                }
                .help("Show logs of the previous (crashed) container instance")
                Toggle(isOn: Binding(get: { model.wrap }, set: { model.wrap = $0; model.controller.setWraps($0) })) {
                    Label("Wrap", systemImage: "text.word.spacing")
                }
                .help("Wrap long lines")
                Button { model.clear() } label: { Label("Clear", systemImage: "trash") }
                    .keyboardShortcut("k")
                    .help("Clear")
                Button { model.restart() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Reload")
            }
        }
    }
}
