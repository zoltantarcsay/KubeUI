import Foundation

/// Untyped JSON, so any Kubernetes object (including CRDs) can be held without a schema.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Uses `JSONSerialization`, which is markedly faster than `JSONDecoder` for large lists.
    public static func parse(_ data: Data) throws -> JSONValue {
        JSONValue(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(any: Any) {
        switch any {
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    /// Dotted keys walk nested objects, e.g. `obj["metadata.name"]`.
    public subscript(key: String) -> JSONValue {
        guard case .object(let o) = self else { return .null }
        if let value = o[key] { return value }
        guard key.contains(".") else { return .null }
        return self[path: key]
    }

    public subscript(index: Int) -> JSONValue {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    public subscript(path path: String) -> JSONValue {
        path.split(separator: ".").reduce(self) { value, key in
            if case .object(let o) = value { return o[String(key)] ?? .null }
            return .null
        }
    }

    public var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): String(b)
        default: nil
        }
    }

    public var int: Int? {
        switch self {
        case .number(let n): Int(n)
        case .string(let s): Int(s)
        default: nil
        }
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }

    public var object: [String: JSONValue] {
        if case .object(let o) = self { return o }
        return [:]
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
