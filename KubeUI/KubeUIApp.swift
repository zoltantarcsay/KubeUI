import KubeKit
import SwiftUI

@main
struct KubeUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("KubeUI", id: "cluster") {
            ClusterWindow()
                .environment(app)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            SidebarCommands()
            InspectorCommands()
            ToolbarCommands()
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
