import KubeKit
import SwiftUI

/// App-wide state shared by all windows: the resolved kubectl.
@Observable
final class AppModel {
    private(set) var kubectl: Kubectl?
    private(set) var setupError: String?
    private var resolving: Task<Kubectl?, Never>?

    static let kubectlPathKey = "kubectlPath"

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            Kubectl.terminateAll()
        }
    }

    /// Resolves kubectl once; concurrent callers share the same lookup.
    @discardableResult
    func ensureKubectl() async -> Kubectl? {
        if let kubectl { return kubectl }
        if resolving == nil {
            let override = UserDefaults.standard.string(forKey: Self.kubectlPathKey)
            resolving = Task {
                do {
                    let resolved = try await Kubectl.resolve(overridePath: override)
                    kubectl = resolved
                    setupError = nil
                    return resolved
                } catch {
                    setupError = error.localizedDescription
                    return nil
                }
            }
        }
        return await resolving?.value
    }

    func reset() async {
        kubectl = nil
        resolving = nil
        await ensureKubectl()
    }

    func client(context: String) async -> KubeClient? {
        guard let kubectl = await ensureKubectl() else { return nil }
        return KubeClient(kubectl: kubectl, context: context)
    }
}

/// Opens a YAML or describe window.
struct TextTarget: Codable, Hashable {
    enum Mode: String, Codable { case yaml, describe }
    let context: String
    let kindID: String
    let name: String
    let namespace: String?
    let mode: Mode
}
