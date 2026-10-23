import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A Dock click on an app that's already active only sends "reopen"; raise and focus the window
    /// explicitly so it can't stay behind other apps' windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard flag else { return true } // no windows: let SwiftUI open one
        let windows = sender.orderedWindows.filter { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain }
        for window in windows.reversed() { window.orderFront(nil) }
        windows.first?.makeKeyAndOrderFront(nil)
        sender.activate()
        return false
    }
}
