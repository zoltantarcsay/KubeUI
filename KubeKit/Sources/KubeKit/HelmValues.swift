import Foundation

/// One layer of an Argo CD Helm app's values, lowest precedence first: the chart's own
/// values.yaml, each `helm.valueFiles` entry in order, then inline `helm.values`.
public struct ValueLayer: Sendable, Identifiable, Hashable {
    public enum Origin: Sendable, Hashable {
        case chartDefaults
        case valueFile
        /// Inline `helm.values` in the Application, usually rendered by its ApplicationSet.
        case inline(owner: String)
    }

    public var id: String { title }
    public let origin: Origin
    /// Path as Argo shows it, e.g. `clients/acme/tst/eu-west-1/demo-ops-app.yaml`.
    public let title: String
    /// Local file, when the source repo is linked.
    public let file: URL?
    public let exists: Bool
    public let text: String

    public var isEditable: Bool {
        if case .inline = origin { return false }
        return file != nil
    }
}

/// One key of the merged values, with the layer that wins it.
public struct ValueNode: Sendable, Identifiable, Hashable {
    public var id: String { path.joined(separator: "\u{1F}") }
    public let path: [String]
    public var key: String { path.last ?? "" }
    public let kind: YAMLEdit.Kind
    /// Display value: the unquoted scalar, a list summary, or empty for mappings.
    public let value: String
    /// The effective value as written in the winning layer (for editing).
    public let rawValue: String
    /// Index of the layer that wins.
    public let layer: Int
    /// Every layer that sets this key (earlier ones are overridden, or merged for mappings).
    public let definedIn: [Int]
    /// Nested keys of a mapping; nil for leaves (as `Table`/`OutlineGroup` expect).
    public var children: [ValueNode]?

    public var dottedPath: String { path.joined(separator: ".") }
}

public enum HelmValues {
    /// Resolves the app's value layers. `localRoot` maps a source repoURL to the user's clone.
    public static func layers(for app: ArgoApplication, localRoot: (String) -> URL?) -> [ValueLayer] {
        guard let chart = app.sources.first(where: { $0.path != nil && $0.ref == nil }) ?? app.sources.first(where: { $0.path != nil }) else {
            return []
        }
        var layers: [ValueLayer] = []
        func layer(_ origin: ValueLayer.Origin, repoURL: String, path: String) -> ValueLayer {
            let file = localRoot(repoURL)?.appendingPathComponent(path)
            let text = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            return ValueLayer(origin: origin, title: path, file: file, exists: text != nil, text: text ?? "")
        }
        let chartPath = chart.path!
        layers.append(layer(.chartDefaults, repoURL: chart.repoURL, path: (chartPath as NSString).appendingPathComponent("values.yaml")))
        for valueFile in chart.helmValueFiles {
            if valueFile.hasPrefix("$"), let slash = valueFile.firstIndex(of: "/") {
                // `$ref/path` points into another source's repo.
                let ref = String(valueFile[valueFile.index(after: valueFile.startIndex)..<slash])
                let repo = app.sources.first { $0.ref == ref }?.repoURL ?? chart.repoURL
                layers.append(layer(.valueFile, repoURL: repo, path: String(valueFile[valueFile.index(after: slash)...])))
            } else {
                let path = ((chartPath as NSString).appendingPathComponent(valueFile) as NSString).standardizingPath
                layers.append(layer(.valueFile, repoURL: chart.repoURL, path: path))
            }
        }
        if let inline = chart.helmValues, !inline.isEmpty {
            let owner = app.applicationSet.map { "ApplicationSet \($0)" } ?? "Application \(app.name)"
            layers.append(ValueLayer(origin: .inline(owner: owner), title: "Inline values (\(owner))", file: nil, exists: true, text: inline))
        }
        return layers
    }

    /// Merges the layers the way Helm does: mappings merge key by key, scalars and lists from
    /// later layers replace earlier ones wholesale.
    public static func tree(_ layers: [ValueLayer]) -> [ValueNode] {
        struct Info { var kind: YAMLEdit.Kind; var value: String; var raw: String; var layer: Int; var definedIn: [Int] }
        var info: [[String]: Info] = [:]
        var order: [[String]] = []
        for (i, layer) in layers.enumerated() {
            let yaml = YAMLEdit(layer.text)
            for entry in yaml.scan() {
                let path = entry.path
                if entry.kind != .mapping {
                    // A replaced value drops whatever earlier layers nested under it.
                    for p in order where p.count > path.count && Array(p.prefix(path.count)) == path { info[p] = nil }
                }
                let display: String = switch entry.kind {
                case .mapping: ""
                case .list: entry.rawValue.isEmpty ? listSummary(yaml.body(entry)) : entry.rawValue
                case .scalar: entry.rawValue.hasPrefix("|") || entry.rawValue.hasPrefix(">")
                    ? yaml.body(entry).trimmingCharacters(in: .whitespacesAndNewlines) : entry.value
                }
                if info[path] == nil, !order.contains(path) { order.append(path) }
                info[path] = Info(kind: entry.kind, value: display, raw: entry.rawValue, layer: i, definedIn: (info[path]?.definedIn ?? []) + [i])
            }
        }
        func build(_ parent: [String]) -> [ValueNode] {
            order.filter { $0.count == parent.count + 1 && Array($0.dropLast()) == parent && info[$0] != nil }.map { path in
                let i = info[path]!
                return ValueNode(path: path, kind: i.kind, value: i.value, rawValue: i.raw, layer: i.layer, definedIn: i.definedIn,
                                 children: i.kind == .mapping ? build(path) : nil)
            }
        }
        return build([])
    }

    static func listSummary(_ body: String) -> String {
        let items = body.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") || $0.trimmingCharacters(in: .whitespaces) == "-" }
        return "[\(items.count) item\(items.count == 1 ? "" : "s")]"
    }

    /// All nodes, depth first.
    public static func flatten(_ nodes: [ValueNode]) -> [ValueNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }

    static func sets(_ layer: ValueLayer, _ path: [String]) -> Bool {
        YAMLEdit(layer.text).entry(path) != nil
    }

    /// Where an edit of `path` should go by default. The winning file is edited in place when it is
    /// already specific (any value file after the first); values coming from shared layers (chart
    /// defaults, the first value file such as `defaults/...`) get an override in the most specific
    /// file instead, so other tenants are unaffected. nil when inline values pin the path.
    public static func targetLayer(for path: [String], in layers: [ValueLayer]) -> Int? {
        let setters = layers.indices.filter { sets(layers[$0], path) }
        if let top = setters.last, !layers[top].isEditable { return nil }
        let files = layers.indices.filter { layers[$0].origin == .valueFile && layers[$0].file != nil }
        if let top = setters.last, files.dropFirst().contains(top) { return top }
        return files.last
    }

    /// The inline layer that sets `path`, which no values file can override.
    public static func pinnedInline(_ path: [String], in layers: [ValueLayer]) -> ValueLayer? {
        layers.last { layer in
            if case .inline = layer.origin { return sets(layer, path) }
            return false
        }
    }
}
