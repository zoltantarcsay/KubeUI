import KubeKit
import SwiftUI

@main
struct KubeUIApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("KubeUI", id: "cluster") {
            ClusterWindow()
                .environment(app)
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            SidebarCommands()
            InspectorCommands()
            ToolbarCommands()
        }

        WindowGroup("Files", id: "files", for: PodRef.self) { $pod in
            if let pod {
                PodFilesWindow(pod: pod)
                    .environment(app)
            }
        }
        .defaultSize(width: 860, height: 520)
        .restorationBehavior(.disabled)

        WindowGroup("Logs", id: "logs", for: PodRef.self) { $pod in
            if let pod {
                LogsWindow(pod: pod)
                    .environment(app)
            }
        }
        .defaultSize(width: 900, height: 560)
        .restorationBehavior(.disabled)

        WindowGroup("Resource", id: "text", for: TextTarget.self) { $target in
            if let target {
                TextWindow(target: target)
                    .environment(app)
            }
        }
        .defaultSize(width: 760, height: 640)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
