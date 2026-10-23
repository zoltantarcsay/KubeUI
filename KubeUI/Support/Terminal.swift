import AppKit

enum Terminal {
    /// Opens the user's default terminal app running `command`, via a throwaway .command script.
    static func run(_ command: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kubeui-shell-\(UUID().uuidString.prefix(8)).command")
        let script = """
        #!/bin/sh
        rm -f "$0"
        clear
        exec \(command)

        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}
