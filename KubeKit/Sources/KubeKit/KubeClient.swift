import Foundation

/// Cluster operations for one kubeconfig context. Never changes the kubeconfig's current context.
public struct KubeClient: Sendable {
    public let kubectl: Kubectl
    public let context: String

    public init(kubectl: Kubectl, context: String) {
        self.kubectl = kubectl
        self.context = context
    }

    public static func contexts(_ kubectl: Kubectl) async throws -> (contexts: [KubeContext], current: String?) {
        let config = try JSONValue.parse(try await kubectl.run(["config", "view", "-o", "json"]))
        let contexts = config["contexts"].array.compactMap { entry -> KubeContext? in
            guard let name = entry["name"].string else { return nil }
            return KubeContext(name: name, cluster: entry["context.cluster"].string ?? "", namespace: entry["context.namespace"].string)
        }
        let current = config["current-context"].string
        return (contexts, current?.isEmpty == false ? current : nil)
    }

    /// Flags go after the subcommand (kubectl rejects non-global flags before it) but before any `--`.
    func args(_ rest: [String], namespace: String? = nil, allNamespaces: Bool = false) -> [String] {
        var flags = ["--context", context]
        if let namespace { flags += ["--namespace", namespace] } else if allNamespaces { flags.append("--all-namespaces") }
        var result = rest
        result.insert(contentsOf: flags, at: rest.firstIndex(of: "--") ?? rest.endIndex)
        return result
    }

    private func scope(_ kind: ResourceKind, _ namespace: String?) -> (String?, Bool) {
        kind.namespaced ? (namespace, namespace == nil) : (nil, false)
    }

    public func namespaces() async throws -> [String] {
        let list = try JSONValue.parse(try await kubectl.run(args(["get", "namespaces", "-o", "json"])))
        return list["items"].array.compactMap { $0["metadata.name"].string }.sorted()
    }

    /// `namespace == nil` means all namespaces.
    public func list(_ kind: ResourceKind, namespace: String?) async throws -> [KubeObject] {
        let (ns, all) = scope(kind, namespace)
        let data = try await kubectl.run(args(["get", kind.id, "-o", "json"], namespace: ns, allNamespaces: all))
        return try JSONValue.parse(data)["items"].array.map(KubeObject.init)
    }

    public enum WatchUpdate: Sendable {
        /// Full replacement of the current state.
        case snapshot([KubeObject])
        case event(WatchEvent)
    }

    /// Lists, then streams changes. When the server ends the watch it re-lists and resumes,
    /// so the consumer never holds objects that were deleted while disconnected.
    public func watch(_ kind: ResourceKind, namespace: String?) -> AsyncThrowingStream<WatchUpdate, Error> {
        let (ns, all) = scope(kind, namespace)
        let watchArgs = args(["get", kind.id, "-o", "json", "--watch", "--output-watch-events"], namespace: ns, allNamespaces: all)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var backoff: Duration = .seconds(1)
                while !Task.isCancelled {
                    do {
                        continuation.yield(.snapshot(try await list(kind, namespace: namespace)))
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    do {
                        var splitter = JSONStreamSplitter()
                        for try await chunk in kubectl.stream(watchArgs) {
                            for data in splitter.feed(chunk) {
                                guard let json = try? JSONValue.parse(data),
                                      let type = json["type"].string.flatMap(WatchEvent.Kind.init(rawValue:)),
                                      type != .bookmark, type != .error else { continue }
                                continuation.yield(.event(WatchEvent(kind: type, object: KubeObject(json["object"]))))
                            }
                        }
                        backoff = .seconds(1)
                    } catch is CancellationError {
                        break
                    } catch {
                        try? await Task.sleep(for: backoff)
                        backoff = min(backoff * 2, .seconds(30))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func get(_ kind: ResourceKind, name: String, namespace: String?) async throws -> KubeObject {
        let data = try await kubectl.run(args(["get", kind.id, name, "-o", "json"], namespace: kind.namespaced ? namespace : nil))
        return KubeObject(try JSONValue.parse(data))
    }

    public func yaml(_ kind: ResourceKind, name: String, namespace: String?) async throws -> String {
        try await kubectl.runString(args(["get", kind.id, name, "-o", "yaml"], namespace: kind.namespaced ? namespace : nil))
    }

    public func describe(_ kind: ResourceKind, name: String, namespace: String?) async throws -> String {
        try await kubectl.runString(args(["describe", kind.id, name], namespace: kind.namespaced ? namespace : nil))
    }

    public func delete(_ kind: ResourceKind, name: String, namespace: String?) async throws {
        _ = try await kubectl.run(args(["delete", kind.id, name, "--wait=false"], namespace: kind.namespaced ? namespace : nil))
    }

    public func scale(_ kind: ResourceKind, name: String, namespace: String?, replicas: Int) async throws {
        _ = try await kubectl.run(args(["scale", kind.id, name, "--replicas=\(replicas)"], namespace: namespace))
    }

    public func restart(_ kind: ResourceKind, name: String, namespace: String?) async throws {
        _ = try await kubectl.run(args(["rollout", "restart", "\(kind.id)/\(name)"], namespace: namespace))
    }

    public func logs(pod: String, namespace: String, container: String?, tail: Int, follow: Bool, previous: Bool = false) -> AsyncThrowingStream<Data, Error> {
        var rest = ["logs", pod, "--tail=\(tail)"]
        if let container { rest += ["--container", container] }
        if follow { rest.append("--follow") }
        if previous { rest.append("--previous") }
        return kubectl.stream(args(rest, namespace: namespace))
    }

    /// Shell command line for an interactive session, for handing to Terminal.
    public func shellCommand(pod: String, namespace: String, container: String?) -> String {
        var parts = [kubectl.executable.path] + args(["exec", "-it", pod], namespace: namespace)
        if let container { parts += ["--container", container] }
        parts += ["--", "sh", "-c", "command -v bash >/dev/null && exec bash || exec sh"]
        return parts.map(shellQuote).joined(separator: " ")
    }
}

public func shellQuote(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@,".contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
