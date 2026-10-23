import Foundation

/// A container image reference split into its parts, e.g.
/// `123456789012.dkr.ecr.eu-west-1.amazonaws.com/my-app:1.2.3` or `busybox:1.36`.
public struct ImageReference: Sendable, Hashable {
    public let registry: String
    public let repository: String
    /// nil when the image is pinned by digest only.
    public let tag: String?
    public let digest: String?

    public init(_ reference: String) {
        var rest = reference.trimmingCharacters(in: .whitespaces)
        if let at = rest.firstIndex(of: "@") {
            digest = String(rest[rest.index(after: at)...])
            rest = String(rest[..<at])
        } else {
            digest = nil
        }
        // A tag is a ":" after the last "/", so registry ports aren't mistaken for tags.
        let lastSlash = rest.lastIndex(of: "/") ?? rest.startIndex
        if let colon = rest[lastSlash...].lastIndex(of: ":") {
            tag = String(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
        } else {
            tag = digest == nil ? "latest" : nil
        }
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost" {
            registry = parts[0]
            repository = parts[1]
        } else {
            registry = "docker.io"
            repository = parts.count == 1 ? "library/" + rest : rest
        }
    }

    /// Human name of well-known registries.
    public var registryName: String {
        if registry.contains(".dkr.ecr.") { return "Amazon ECR (\(registry.split(separator: ".").first ?? ""), \(registry.split(separator: ".")[safe: 3] ?? ""))" }
        switch registry {
        case "docker.io": return "Docker Hub"
        case "ghcr.io": return "GitHub Container Registry"
        case "quay.io": return "Quay"
        case "registry.k8s.io": return "Kubernetes registry"
        default: return registry.hasSuffix("gcr.io") || registry.hasSuffix("pkg.dev") ? "Google (\(registry))" : registry
        }
    }

    /// The `sha256:…` digest from a container status `imageID`, whatever the runtime prefix
    /// (`docker-pullable://repo@sha256:…`, `repo@sha256:…` or a bare `sha256:…`).
    public static func digest(fromImageID imageID: String) -> String? {
        if let at = imageID.lastIndex(of: "@") { return String(imageID[imageID.index(after: at)...]) }
        if let range = imageID.range(of: "sha256:") { return String(imageID[range.lowerBound...]) }
        return nil
    }

    /// Web page for the image on registries that have one.
    public var webURL: URL? {
        switch registry {
        case "docker.io":
            let name = repository.hasPrefix("library/") ? "_/" + repository.dropFirst(8) : "r/" + repository
            return URL(string: "https://hub.docker.com/\(name)")
        case "ghcr.io", "quay.io":
            return URL(string: "https://\(registry)/\(repository)")
        default:
            return nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
