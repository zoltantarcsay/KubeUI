#if DEBUG
import AppKit
import KubeKit
import SwiftUI

/// Debug-build hooks for scripted UI checks without screen-recording permission:
/// `KUBEUI_SNAPSHOT_DIR=<dir>` writes a PNG of every window every 2s;
/// `KUBEUI_OPEN=files:<namespace>/<pod>,logs:<namespace>/<pod>` opens those panel tabs at launch;
/// `KUBEUI_EXPAND=/etc,/usr` expands folders in the last opened Files tab.
struct DebugHooks: ViewModifier {
    let model: ClusterModel
    private static var started = false

    func body(content: Content) -> some View {
        content.task(id: model.context) {
            let env = ProcessInfo.processInfo.environment
            if let dir = env["KUBEUI_SNAPSHOT_DIR"], !Self.started {
                Self.started = true
                Task { await Self.snapshotLoop(URL(fileURLWithPath: dir)) }
            }
            guard let specs = env["KUBEUI_OPEN"], let context = model.context, let client = model.client else { return }
            for spec in specs.split(separator: ",") {
                let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                let path = parts.last?.split(separator: "/").map(String.init) ?? []
                guard parts.count == 2, path.count == 2,
                      let pod = try? await client.get(.pods, name: path[1], namespace: path[0]) else { continue }
                let ref = PodRef(context: context, namespace: path[0], pod: path[1], containers: pod.containerNames)
                model.openPanel(parts[0] == "logs" ? .logs(ref) : .files(ref))
            }
            if let expand = env["KUBEUI_EXPAND"], case .files(let files)? = model.activePanel?.content {
                try? await Task.sleep(for: .seconds(3))
                for path in expand.split(separator: ",") { files.setExpanded(String(path), true) }
            }
        }
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
