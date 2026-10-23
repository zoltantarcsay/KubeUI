import AppKit
import KubeKit
import SwiftTerm
import SwiftUI

/// An interactive `kubectl exec -it` session in a terminal emulator (SwiftTerm). The terminal view
/// lives as long as the panel tab, so switching tabs keeps the session running.
@Observable
final class ShellModel: NSObject, LocalProcessTerminalViewDelegate {
    let pod: PodRef
    var container: String?
    private(set) var title = ""
    private(set) var exitCode: Int32??
    private(set) var error: String?
    @ObservationIgnored let terminal: LocalProcessTerminalView
    @ObservationIgnored private var app: AppModel?

    init(pod: PodRef, container: String?) {
        self.pod = pod
        self.container = container ?? pod.containers.first
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        super.init()
        terminal.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // Match the app's light or dark appearance instead of SwiftTerm's fixed black.
        terminal.nativeBackgroundColor = .textBackgroundColor
        terminal.nativeForegroundColor = .textColor
        terminal.caretColor = .controlAccentColor
        terminal.processDelegate = self
    }

    var isRunning: Bool { exitCode == nil && error == nil && app != nil }

    func start(app: AppModel) {
        self.app = app
        Task { await launch() }
    }

    func launch() async {
        guard let app, let client = await app.client(context: pod.context), let kubectl = await app.ensureKubectl() else {
            error = app?.setupError ?? "kubectl isn't available"
            return
        }
        exitCode = nil
        error = nil
        title = container ?? pod.pod
        var env = kubectl.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        terminal.getTerminal().resetToInitialState()
        terminal.startProcess(
            executable: kubectl.executable.path,
            args: client.shellArguments(pod: pod.pod, namespace: pod.namespace, container: container),
            environment: env.map { "\($0.key)=\($0.value)" }
        )
        focus()
    }

    func switchContainer(_ name: String) {
        guard name != container else { return }
        container = name
        stop()
        Task { await launch() }
    }

    func stop() {
        if exitCode == nil { terminal.terminate() }
    }

    func focus() {
        DispatchQueue.main.async { [terminal] in terminal.window?.makeFirstResponder(terminal) }
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in if !title.isEmpty { self.title = title } }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.exitCode = .some(exitCode) }
    }
}

struct ShellPanel: View {
    let model: ShellModel

    var body: some View {
        VStack(spacing: 0) {
            TerminalHost(model: model)
                .overlay(alignment: .bottom) {
                    if let ended = model.exitCode {
                        banner("Session ended\(ended.map { " (exit \($0))" } ?? "")", button: "Reconnect")
                    } else if let error = model.error {
                        banner(error, button: "Retry")
                    }
                }
            Divider()
            PanelBar {
                Image(systemName: model.isRunning ? "terminal.fill" : "terminal").foregroundStyle(model.isRunning ? .green : .secondary)
                Text(model.title).font(.callout).lineLimit(1).truncationMode(.middle)
                Text("\(model.pod.pod) · \(model.pod.namespace)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.pod.containers.count > 1 {
                    Picker("Container", selection: Binding(get: { model.container ?? "" }, set: { model.switchContainer($0) })) {
                        ForEach(model.pod.containers, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Container")
                }
                Button { model.stop(); Task { await model.launch() } } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    .help("Start a new session")
            }
        }
        .onAppear { model.focus() }
    }

    private func banner(_ text: String, button: String) -> some View {
        HStack {
            Text(text).font(.callout)
            Button(button) { Task { await model.launch() } }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }
}

/// Hosts the model's long-lived terminal view.
private struct TerminalHost: NSViewRepresentable {
    let model: ShellModel

    func makeNSView(context: Context) -> LocalProcessTerminalView { model.terminal }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}
