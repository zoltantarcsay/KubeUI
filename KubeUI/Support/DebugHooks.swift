import AppKit
import KubeKit
import SwiftUI

#if DEBUG

/// Debug-build hooks for scripted UI checks without screen-recording permission:
/// `KUBEUI_SNAPSHOT_DIR=<dir>` writes a PNG of every window every 2s;
/// `KUBEUI_OPEN=files:<namespace>/<pod>,logs:<namespace>/<pod>` opens those panel tabs at launch;
/// `KUBEUI_EXPAND=/etc,/usr` expands folders in the last opened Files tab;
/// `KUBEUI_OPEN=app:<namespace>/<application>` opens an Argo CD application;
/// `KUBEUI_OPEN=shell:<namespace>/<pod>` opens a shell, typing `KUBEUI_SHELL_INPUT` (`\n` for Return).
struct DebugHooks: ViewModifier {
    let model: ClusterModel
    private static var started = false
    /// `KUBEUI_INSPECT=<namespace>/<pod>` selects that pod with the inspector shown.
    static let showsInspector = ProcessInfo.processInfo.environment["KUBEUI_INSPECT"] != nil
    /// `KUBEUI_VALUES_SEARCH=<text>` pre-fills the Values search.
    static let valuesSearch = ProcessInfo.processInfo.environment["KUBEUI_VALUES_SEARCH"] ?? ""

    func body(content: Content) -> some View {
        content.task(id: model.context) {
            let env = ProcessInfo.processInfo.environment
            if let dir = env["KUBEUI_SNAPSHOT_DIR"], !Self.started {
                Self.started = true
                Task { await Self.snapshotLoop(URL(fileURLWithPath: dir)) }
            }
            if let inspect = env["KUBEUI_INSPECT"] {
                let parts = inspect.split(separator: "/").map(String.init)
                for _ in 0..<40 {
                    if let pod = model.objects.values.first(where: { $0.namespace == parts.first && $0.name == parts.last }) {
                        model.selection = [pod.id]
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            guard let specs = env["KUBEUI_OPEN"], let context = model.context, let client = model.client else { return }
            for spec in specs.split(separator: ",") {
                let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                let path = parts.last?.split(separator: "/").map(String.init) ?? []
                guard parts.count == 2, path.count == 2 else { continue }
                if parts[0] == "app" {
                    guard let object = try? await client.get(.argoApplications, name: path[1], namespace: path[0]) else { continue }
                    model.openApplication(object)
                    await Self.scriptRollout(model, env: env)
                    continue
                }
                guard let pod = try? await client.get(.pods, name: path[1], namespace: path[0]) else { continue }
                let ref = PodRef(context: context, namespace: path[0], pod: path[1], containers: pod.containerNames)
                switch parts[0] {
                case "logs": model.openPanel(.logs(ref))
                case "shell":
                    model.openPanel(.shell(ref, container: nil))
                    if let input = env["KUBEUI_SHELL_INPUT"], case .shell(let shell)? = model.activePanel?.content {
                        try? await Task.sleep(for: .seconds(4))
                        shell.terminal.send(txt: input.replacingOccurrences(of: "\\n", with: "\n"))
                    }
                default: model.openPanel(.files(ref))
                }
            }
            if let expand = env["KUBEUI_EXPAND"], case .files(let files)? = model.activePanel?.content {
                try? await Task.sleep(for: .seconds(3))
                for path in expand.split(separator: ",") { files.setExpanded(String(path), true) }
            }
        }
    }

    /// `KUBEUI_VALUE_SET=a.b.KEY=VALUE` edits the opened app's values like the edit sheet would;
    /// `KUBEUI_PUSH=1` then commits and pushes; `KUBEUI_OPEN_LAYER=<n>` opens layer n in the editor.
    static func scriptRollout(_ model: ClusterModel, env: [String: String]) async {
        guard let app = model.focusedApp else { return }
        for _ in 0..<40 where app.layers.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
        if let n = env["KUBEUI_OPEN_LAYER"].flatMap(Int.init) { app.openLayer(n) }
        guard let spec = env["KUBEUI_VALUE_SET"], let eq = spec.firstIndex(of: "=") else { return }
        let path = spec[..<eq].split(separator: ".").map(String.init), input = String(spec[spec.index(after: eq)...])
        let previous = HelmValues.flatten(app.tree).first { $0.path == path }?.rawValue
        guard let layer = HelmValues.targetLayer(for: path, in: app.layers) else { return }
        app.setValue(path, literal: YAMLEdit.literal(from: input, previous: previous), layer: layer)
        guard env["KUBEUI_PUSH"] == "1" else { return }
        try? await Task.sleep(for: .seconds(3))
        await app.commitAndPush("\(app.application.name): set \(path.last!)")
    }

    static func snapshotLoop(_ dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        while true {
            for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = window.title.isEmpty ? "window-\(i)" : window.title.replacingOccurrences(of: "/", with: "_")
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
                try? dump(view).write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// View tree with frames, plus row counts of tables, for checking parts that don't snapshot (glass, vibrancy).
    static func dump(_ view: NSView, depth: Int = 0) -> String {
        var line = String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame.integral)" + (view.isHidden ? " hidden" : "")
        if let table = view as? NSTableView { line += " rows=\(table.numberOfRows)" }
        if let text = view as? NSTextField { line += " \"\(text.stringValue)\"" }
        if let text = view as? NSTextView { line += " chars=\(text.string.count)" }
        return ([line] + view.subviews.map { dump($0, depth: depth + 1) }).joined(separator: "\n")
    }
}
#else
enum DebugHooks {
    static let showsInspector = false
    static let valuesSearch = ""
}
#endif

extension View {
    func debugHooks(_ model: ClusterModel) -> some View {
        #if DEBUG
        modifier(DebugHooks(model: model))
        #else
        self
        #endif
    }
}
