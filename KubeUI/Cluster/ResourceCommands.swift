import SwiftUI

/// Actions on the selected row of the resource table; nil when they don't apply.
struct ResourceActions {
    var showYAML: (() -> Void)?
    var describe: (() -> Void)?
    var browseFiles: (() -> Void)?
    var showLogs: (() -> Void)?
    var openShell: (() -> Void)?
    var openShellInTerminal: (() -> Void)?
}

extension FocusedValues {
    @Entry var resourceActions: ResourceActions?
}

/// The Resource menu, so table actions get working keyboard shortcuts.
struct ResourceCommands: Commands {
    @FocusedValue(\.resourceActions) private var actions

    var body: some Commands {
        CommandMenu("Resource") {
            item("Show YAML", actions?.showYAML, .showYAML)
            item("Describe", actions?.describe, .describe)
            Divider()
            item("Browse Files", actions?.browseFiles, .browseFiles)
            item("Show Logs", actions?.showLogs, .showLogs)
            item("Open Shell", actions?.openShell, .openShell)
            item("Open Shell in Terminal", actions?.openShellInTerminal, .openShellInTerminal)
        }
    }

    private func item(_ title: String, _ action: (() -> Void)?, _ shortcut: KeyboardShortcut) -> some View {
        Button(title) { action?() }
            .keyboardShortcut(shortcut)
            .disabled(action == nil)
    }
}

extension KeyboardShortcut {
    static let showYAML = KeyboardShortcut("y")
    static let describe = KeyboardShortcut("d")
    static let browseFiles = KeyboardShortcut("b")
    static let showLogs = KeyboardShortcut("l")
    static let openShell = KeyboardShortcut("t")
    static let openShellInTerminal = KeyboardShortcut("t", modifiers: [.command, .shift])
}
