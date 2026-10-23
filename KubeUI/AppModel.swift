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

    /// Local clones of GitOps repos, keyed by normalized repo URL.
    private(set) var repoLinks: [String: String] = UserDefaults.standard.dictionary(forKey: "repoLinks") as? [String: String] ?? [:]

    func linkedRoot(for repoURL: String) -> URL? {
        repoLinks.first { GitRepo.sameRepo($0.key, repoURL) }.map { URL(fileURLWithPath: $0.value) }
    }

    func link(repoURL: String, to folder: URL) {
        repoLinks = repoLinks.filter { !GitRepo.sameRepo($0.key, repoURL) }
        repoLinks[repoURL] = folder.path
        UserDefaults.standard.set(repoLinks, forKey: "repoLinks")
    }

    enum LinkResult {
        case linked(warning: String?)
        case failed(String)
    }

    /// Links the clone containing `folder` after checking it's a git repo whose origin is `repoURL`.
    /// A different origin is linked with a warning (forks and mirrors are legitimate).
    func linkRepo(_ folder: URL, to repoURL: String) async -> LinkResult {
        guard let kubectl = await ensureKubectl() else { return .failed(setupError ?? "kubectl isn't available") }
        guard let repo = try? await GitRepo.open(folder, environment: kubectl.environment) else {
            return .failed("\(folder.path) isn't inside a git repository. Choose the folder you cloned \(repoURL) into.")
        }
        let picked = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let inside = repo.root.resolvingSymlinksInPath().standardizedFileURL.path == picked ? "" : " (the folder you picked is inside it)"
        guard let origin = try? await repo.remoteURL(), !origin.isEmpty else {
            return .failed("The git repository at \(repo.root.path)\(inside) has no origin remote, so it isn't a clone of \(repoURL). Choose the folder you cloned it into.")
        }
        link(repoURL: repoURL, to: repo.root)
        if GitRepo.sameRepo(origin, repoURL) { return .linked(warning: nil) }
        return .linked(warning: "Linked \(repo.root.path)\(inside), but its origin is \(origin), not \(repoURL). If that's the wrong clone, link another folder from the app's Source card.")
    }

    func unlink(repoURL: String) {
        repoLinks = repoLinks.filter { !GitRepo.sameRepo($0.key, repoURL) }
        UserDefaults.standard.set(repoLinks, forKey: "repoLinks")
    }

    func client(context: String) async -> KubeClient? {
        guard let kubectl = await ensureKubectl() else { return nil }
        return KubeClient(kubectl: kubectl, context: context)
    }
}

/// What a YAML or describe panel shows.
struct TextTarget: Hashable {
    enum Mode: String { case yaml, describe }
    let context: String
    let kindID: String
    let name: String
    let namespace: String?
    let mode: Mode
}
