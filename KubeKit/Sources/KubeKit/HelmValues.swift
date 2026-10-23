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

/// An env var's effective value and the layer that sets it.
public struct EnvVar: Sendable, Identifiable, Hashable {
    public var id: String { key }
    public let key: String
    public let value: String
    /// Index into the layers of the layer that wins.
    public let layer: Int
    /// Every layer that sets this key (lower ones are overridden).
    public let definedIn: [Int]
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

    /// Paths of every `env` mapping across the layers, e.g. `["demo-ops", "backend", "env"]`.
    public static func envBlocks(_ layers: [ValueLayer]) -> [[String]] {
        var seen: [[String]] = []
        for layer in layers {
            for path in YAMLEdit(layer.text).mappingPaths(named: "env") where !seen.contains(path) {
                seen.append(path)
            }
        }
        return seen
    }

    /// Effective env vars of one block: maps merge across layers, later layers win.
    public static func env(_ block: [String], in layers: [ValueLayer]) -> [EnvVar] {
        var values: [String: (value: String, layer: Int, definedIn: [Int])] = [:]
        var order: [String] = []
        for (i, layer) in layers.enumerated() {
            for entry in YAMLEdit(layer.text).entries(block) {
                if values[entry.key] == nil { order.append(entry.key) }
                let defined = (values[entry.key]?.definedIn ?? []) + [i]
                values[entry.key] = (entry.value, i, defined)
            }
        }
        return order.sorted().compactMap { key in
            values[key].map { EnvVar(key: key, value: $0.value, layer: $0.layer, definedIn: $0.definedIn) }
        }
    }

    /// Where an edit of `key` should go by default. The key's winning file is edited in place when it
    /// is already specific (any value file after the first); keys coming from shared layers (chart
    /// defaults, the first value file such as `defaults/...`) get an override in the most specific
    /// file instead, so other tenants are unaffected. nil when inline values pin the key.
    public static func targetLayer(for key: String, block: [String], in layers: [ValueLayer]) -> Int? {
        let setters = layers.indices.filter { i in YAMLEdit(layers[i].text).entries(block).contains { $0.key == key } }
        if let top = setters.last, !layers[top].isEditable { return nil }
        let files = layers.indices.filter { layers[$0].origin == .valueFile && layers[$0].file != nil }
        if let top = setters.last, files.dropFirst().contains(top) { return top }
        return files.last
    }

    /// Whether an inline layer sets `key`, which no values file can override.
    public static func pinnedInline(_ key: String, block: [String], in layers: [ValueLayer]) -> ValueLayer? {
        layers.last { layer in
            if case .inline = layer.origin { return YAMLEdit(layer.text).entries(block).contains { $0.key == key } }
            return false
        }
    }
}
