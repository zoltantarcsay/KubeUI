import Foundation

/// Line-based reading and surgical editing of block-style YAML mappings, so edits to GitOps
/// values files keep comments, ordering and formatting (a parse/serialize round trip wouldn't).
/// Flow collections and anchors are not interpreted; lines it doesn't understand are left alone.
public struct YAMLEdit: Sendable {
    public struct Entry: Sendable, Hashable {
        public let key: String
        /// The scalar as written (quotes included); empty for nested mappings.
        public let rawValue: String
        public var value: String { YAMLEdit.unquote(rawValue) }
        public let line: Int
        public let indent: Int
    }

    public private(set) var lines: [String]

    public init(_ text: String) {
        lines = text.components(separatedBy: "\n")
    }

    public var text: String { lines.joined(separator: "\n") }

    struct KeyLine {
        let indent: Int
        let key: String
        let rest: String
    }

    static func parseKey(_ line: String) -> KeyLine? {
        let indent = line.prefix { $0 == " " }.count
        let body = line.dropFirst(indent)
        guard let first = body.first, first != "#", first != "-" else { return nil }
        var key = ""
        var rest = Substring("")
        if first == "\"" || first == "'" {
            guard let close = body.dropFirst().firstIndex(of: first) else { return nil }
            key = String(body[body.index(after: body.startIndex)..<close])
            let after = body[body.index(after: close)...]
            guard after.first == ":" else { return nil }
            rest = after.dropFirst()
        } else {
            guard let colon = body.firstIndex(where: { $0 == ":" }) else { return nil }
            let next = body.index(after: colon)
            guard next == body.endIndex || body[next] == " " else { return nil }
            key = String(body[..<colon])
            rest = body[next...]
        }
        return KeyLine(indent: indent, key: key, rest: stripComment(String(rest)).trimmingCharacters(in: .whitespaces))
    }

    static func stripComment(_ s: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for (i, c) in s.enumerated() {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#", previous == " " {
                return String(s.prefix(i))
            }
            previous = c
        }
        return s
    }

    static func isContent(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !t.hasPrefix("#")
    }

    /// Line index of the mapping key at `path`, if present.
    public func find(_ path: [String]) -> Int? {
        var stack: [(key: String, indent: Int)] = []
        for (i, line) in lines.enumerated() where Self.isContent(line) {
            guard let k = Self.parseKey(line) else { continue }
            while let top = stack.last, top.indent >= k.indent { stack.removeLast() }
            stack.append((k.key, k.indent))
            if stack.map(\.key) == path { return i }
        }
        return nil
    }

    /// Last line belonging to the block that starts at `line` (its deeper-indented children).
    func blockEnd(_ line: Int) -> Int {
        let indent = lines[line].prefix { $0 == " " }.count
        var end = line
        var i = line + 1
        while i < lines.count {
            if Self.isContent(lines[i]) {
                if lines[i].prefix(while: { $0 == " " }).count <= indent { break }
                end = i
            }
            i += 1
        }
        return end
    }

    /// Direct children of the mapping at `path` (the root when empty).
    public func entries(_ path: [String]) -> [Entry] {
        let range: ClosedRange<Int>
        let parentIndent: Int
        if path.isEmpty {
            guard !lines.isEmpty else { return [] }
            range = 0...(lines.count - 1)
            parentIndent = -1
        } else {
            guard let start = find(path) else { return [] }
            let end = blockEnd(start)
            guard end > start else { return [] }
            range = (start + 1)...end
            parentIndent = lines[start].prefix { $0 == " " }.count
        }
        var childIndent: Int?
        var result: [Entry] = []
        for i in range where Self.isContent(lines[i]) {
            guard let k = Self.parseKey(lines[i]), k.indent > parentIndent else { continue }
            if childIndent == nil { childIndent = k.indent }
            guard k.indent == childIndent else { continue }
            result.append(Entry(key: k.key, rawValue: k.rest, line: i, indent: k.indent))
        }
        return result
    }

    /// Every path to a key named `name` holding a mapping (e.g. all `env` blocks).
    public func mappingPaths(named name: String) -> [[String]] {
        var stack: [(key: String, indent: Int)] = []
        var found: [[String]] = []
        for line in lines where Self.isContent(line) {
            guard let k = Self.parseKey(line) else { continue }
            while let top = stack.last, top.indent >= k.indent { stack.removeLast() }
            stack.append((k.key, k.indent))
            if k.key == name, k.rest.isEmpty || k.rest == "{}" { found.append(stack.map(\.key)) }
        }
        return found
    }

    /// Sets `key` under the mapping at `path`, creating missing parents. Keeps the existing
    /// value's quoting style when replacing.
    public mutating func set(_ path: [String], key: String, value: String) {
        if let existing = entries(path).first(where: { $0.key == key }) {
            let style = existing.rawValue.first
            let line = lines[existing.line]
            let comment = trailingComment(line)
            let keyPart = String(line.prefix { $0 != ":" } ) // indent + key as written
            lines[existing.line] = "\(keyPart): \(Self.format(value, style: style))\(comment)"
            return
        }
        let (anchor, indent) = ensure(path)
        let newLine = String(repeating: " ", count: indent) + Self.formatKey(key) + ": " + Self.format(value, style: nil)
        if let anchor {
            lines.insert(newLine, at: blockEnd(anchor) + 1)
        } else {
            insertAtRootEnd(newLine)
        }
    }

    public mutating func remove(_ path: [String], key: String) {
        guard let entry = entries(path).first(where: { $0.key == key }) else { return }
        lines.removeSubrange(entry.line...blockEnd(entry.line))
    }

    /// Makes sure the mapping at `path` exists as a block; returns its key line and child indent.
    mutating func ensure(_ path: [String]) -> (Int?, Int) {
        guard !path.isEmpty else { return (nil, 0) }
        if let line = find(path) {
            // `env: {}` becomes a block mapping.
            if let k = Self.parseKey(lines[line]), k.rest == "{}" {
                lines[line] = String(repeating: " ", count: k.indent) + Self.formatKey(k.key) + ":"
            }
            let indent = lines[line].prefix { $0 == " " }.count
            let children = entries(path)
            return (line, children.first?.indent ?? indent + childStep())
        }
        let (parent, indent) = ensure(Array(path.dropLast()))
        let newLine = String(repeating: " ", count: indent) + Self.formatKey(path.last!) + ":"
        if let parent {
            let at = blockEnd(parent) + 1
            lines.insert(newLine, at: at)
            return (at, indent + childStep())
        }
        insertAtRootEnd(newLine)
        return (find(path), indent + childStep())
    }

    /// Indent step used by the file, guessed from its first nested key.
    func childStep() -> Int {
        for line in lines where Self.isContent(line) {
            let n = line.prefix { $0 == " " }.count
            if n > 0, Self.parseKey(line) != nil { return n }
        }
        return 2
    }

    mutating func insertAtRootEnd(_ line: String) {
        var at = lines.count
        while at > 0, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
        lines.insert(line, at: at)
    }

    func trailingComment(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        let after = String(line[line.index(after: colon)...])
        let comment = after.dropFirst(Self.stripComment(after).count).trimmingCharacters(in: .whitespaces)
        return comment.isEmpty ? "" : " " + comment
    }

    static func formatKey(_ key: String) -> String {
        key.allSatisfy { $0.isLetter || $0.isNumber || "_-./".contains($0) } ? key : "\"\(key)\""
    }

    /// Renders a string scalar, quoting when YAML would otherwise read it as something else.
    static func format(_ value: String, style: Character?) -> String {
        if style == "'" { return "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let plainSafe = !value.isEmpty
            && value.allSatisfy { $0.isLetter || $0.isNumber || "_-./@+=,".contains($0) || $0 == ":" }
            && !value.contains(": ")
            && !["true", "false", "yes", "no", "on", "off", "null", "~"].contains(value.lowercased())
            && Double(value) == nil
            && !"-?:,[]{}#&*!|>'\"%@`".contains(value.first!)
        if style != "\"" && plainSafe { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func unquote(_ raw: String) -> String {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }
}
