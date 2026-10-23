import Foundation

public struct KubeObject: Sendable, Identifiable, Hashable {
    public let raw: JSONValue
    public let id: String
    public let name: String
    public let namespace: String?
    public let kind: String
    public let creationDate: Date?

    public init(_ raw: JSONValue) {
        self.raw = raw
        let meta = raw["metadata"]
        name = meta["name"].string ?? ""
        namespace = meta["namespace"].string
        kind = raw["kind"].string ?? ""
        id = meta["uid"].string ?? "\(namespace ?? "")/\(name)"
        creationDate = meta["creationTimestamp"].string.flatMap(KubeObject.parseDate)
    }

    public var labels: [String: String] { raw["metadata.labels"].object.compactMapValues(\.string) }
    public var annotations: [String: String] { raw["metadata.annotations"].object.compactMapValues(\.string) }

    /// Pod container names, regular containers first.
    public var containerNames: [String] {
        raw["spec.containers"].array.compactMap { $0["name"].string }
    }

    public static func parseDate(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string)
    }
}

public struct WatchEvent: Sendable {
    public enum Kind: String, Sendable {
        case added = "ADDED", modified = "MODIFIED", deleted = "DELETED", bookmark = "BOOKMARK", error = "ERROR"
    }
    public let kind: Kind
    public let object: KubeObject
}

public struct KubeContext: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let cluster: String
    public let namespace: String?
}
