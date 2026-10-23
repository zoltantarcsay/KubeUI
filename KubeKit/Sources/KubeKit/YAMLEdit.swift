import Foundation

/// Line-based reading and surgical editing of block-style YAML mappings, so edits to GitOps
/// values files keep comments, ordering and formatting (a parse/serialize round trip wouldn't).
/// Lists and block scalars are recognised and kept intact but not edited item by item.
public struct YAMLEdit: Sendable {
    public enum Kind: Sendable, Hashable { case mapping, list, scalar }

    public struct Entry: Sendable, Hashable {
        public let path: [String]
        public var key: String { path.last ?? "" }
        public let kind: Kind
        /// The value as written after the colon (quotes included); empty for nested blocks.
        public let rawValue: String
        public var value: String { YAMLEdit.unquote(rawValue) }
        public let line: Int
        /// Last line belonging to this entry (its nested block, list items or block scalar).
        public let end: Int
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

    static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    /// Every mapping key with its path, kind and extent. List items and block scalar bodies
    /// are skipped as a whole, so keys inside list items never leak into the mapping paths.
    public func scan() -> [Entry] {
        var entries: [Entry] = []
        var stack: [(key: String, indent: Int)] = []
        var i = 0
        while i < lines.count {
            guard Self.isContent(lines[i]), let k = Self.parseKey(lines[i]) else { i += 1; continue }
            while let top = stack.last, top.indent >= k.indent { stack.removeLast() }
            let (kind, end) = classify(i, k)
            entries.append(Entry(path: stack.map(\.key) + [k.key], kind: kind, rawValue: k.rest, line: i, end: end, indent: k.indent))
            if kind == .mapping, k.rest.isEmpty {
                stack.append((k.key, k.indent))
                i += 1
            } else {
                i = end + 1
            }
        }
        return entries
    }

    private func classify(_ i: Int, _ k: KeyLine) -> (Kind, Int) {
        if k.rest == "{}" { return (.mapping, i) }
        if k.rest.hasPrefix("[") { return (.list, i) }
        if k.rest.hasPrefix("{") { return (.mapping, i) }
        if k.rest.hasPrefix("|") || k.rest.hasPrefix(">") { return (.scalar, deeperEnd(i, k.indent)) }
        guard k.rest.isEmpty else { return (.scalar, i) }
        guard let next = nextContent(after: i) else { return (.scalar, i) }
        let nextIndent = Self.indent(lines[next])
        let nextIsItem = lines[next].dropFirst(nextIndent).hasPrefix("-")
        if nextIndent > k.indent { return (nextIsItem ? .list : .mapping, nextIsItem ? listEnd(i, k.indent) : deeperEnd(i, k.indent)) }
        if nextIndent == k.indent, nextIsItem { return (.list, listEnd(i, k.indent)) }
        return (.scalar, i)
    }

    private func nextContent(after i: Int) -> Int? {
        var j = i + 1
        while j < lines.count, !Self.isContent(lines[j]) { j += 1 }
        return j < lines.count ? j : nil
    }

    /// Last content line indented deeper than `indent`, following `line`.
    private func deeperEnd(_ line: Int, _ indent: Int) -> Int {
        var end = line
        var j = line + 1
        while j < lines.count {
            if Self.isContent(lines[j]) {
                if Self.indent(lines[j]) <= indent { break }
                end = j
            }
            j += 1
        }
        return end
    }

    /// Like `deeperEnd`, but also takes `- ` items at the key's own indentation.
    private func listEnd(_ line: Int, _ indent: Int) -> Int {
        var end = line
        var j = line + 1
        while j < lines.count {
            if Self.isContent(lines[j]) {
                let n = Self.indent(lines[j])
                guard n > indent || (n == indent && lines[j].dropFirst(n).hasPrefix("-")) else { break }
                end = j
            }
            j += 1
        }
        return end
    }

    public func entry(_ path: [String]) -> Entry? {
        scan().first { $0.path == path }
    }

    /// Direct children of the mapping at `path` (the root when empty).
    public func entries(_ path: [String]) -> [Entry] {
        scan().filter { $0.path.count == path.count + 1 && Array($0.path.dropLast()) == path }
    }

    /// Sets `key` under the mapping at `path` to a string, quoting as needed and keeping the
    /// existing value's quoting style when replacing a scalar.
    public mutating func set(_ path: [String], key: String, value: String) {
        let style = entries(path).first { $0.key == key && $0.kind == .scalar }?.rawValue.first
        setLiteral(path, key: key, literal: Self.format(value, style: style))
    }

    /// Sets `key` to a YAML literal as written (e.g. `3`, `true`, `"text"`), creating missing
    /// parents. A nested block or list at that key is replaced by the literal.
    public mutating func setLiteral(_ path: [String], key: String, literal: String) {
        if let existing = entries(path).first(where: { $0.key == key }) {
            let line = lines[existing.line]
            let comment = existing.kind == .scalar && existing.end == existing.line ? trailingComment(line) : ""
            let keyPart = String(line.prefix(existing.indent)) + Self.formatKey(key)
            lines.replaceSubrange(existing.line...existing.end, with: ["\(keyPart): \(literal)\(comment)"])
            return
        }
        let (anchor, indent) = ensure(path)
        let newLine = String(repeating: " ", count: indent) + Self.formatKey(key) + ": " + literal
        if let anchor {
            lines.insert(newLine, at: anchor + 1)
        } else {
            insertAtRootEnd(newLine)
        }
    }

    public mutating func remove(_ path: [String], key: String) {
        guard let entry = entries(path).first(where: { $0.key == key }) else { return }
        lines.removeSubrange(entry.line...entry.end)
    }

    /// Makes sure the mapping at `path` exists as a block; returns the line after which a new
    /// child goes (its last line) and the child indentation.
    mutating func ensure(_ path: [String]) -> (Int?, Int) {
        guard !path.isEmpty else { return (nil, 0) }
        if let e = entry(path) {
            if e.kind != .mapping || e.rawValue == "{}" {
                // `env: {}` (or a scalar being turned into a mapping) becomes a block mapping.
                lines.replaceSubrange(e.line...e.end, with: [String(repeating: " ", count: e.indent) + Self.formatKey(e.key) + ":"])
                return (e.line, e.indent + childStep())
            }
            let children = entries(path)
            return (e.end, children.first?.indent ?? e.indent + childStep())
        }
        let (parent, indent) = ensure(Array(path.dropLast()))
        let newLine = String(repeating: " ", count: indent) + Self.formatKey(path.last!) + ":"
        if let parent {
            lines.insert(newLine, at: parent + 1)
            return (parent + 1, indent + childStep())
        }
        insertAtRootEnd(newLine)
        return (entry(path)?.line, indent + childStep())
    }

    /// Indent step used by the file, guessed from its first nested key.
    func childStep() -> Int {
        for line in lines where Self.isContent(line) {
            let n = Self.indent(line)
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
        let plainSafe = isPlainSafe(value)
            && !["true", "false", "yes", "no", "on", "off", "null", "~"].contains(value.lowercased())
            && Double(value) == nil
        if style != "\"" && plainSafe { return value }
        return quoted(value)
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Whether `value` can be written unquoted without being misread or breaking the line.
    static func isPlainSafe(_ value: String) -> Bool {
        guard let first = value.first, first != " ", value.last != " " else { return false }
        return !value.contains(": ") && !value.contains(" #") && !value.contains("\n")
            && !"-?:,[]{}#&*!|>'\"%@`".contains(first)
    }

    /// Turns what the user typed into a YAML literal. Typed quotes and plain scalars (numbers,
    /// booleans, words) are kept as typed, so `3` stays a number; anything that would break the
    /// YAML gets quoted. Values that were quoted before stay quoted, so strings stay strings.
    public static func literal(from input: String, previous raw: String?) -> String {
        if let q = raw?.first, q == "\"" || q == "'" { return format(input, style: q) }
        if input.count >= 2, let q = input.first, q == "\"" || q == "'", input.last == q { return input }
        return isPlainSafe(input) ? input : quoted(input)
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

    /// The text of an entry's nested lines (list items, block scalar body), for display.
    public func body(_ entry: Entry) -> String {
        guard entry.end > entry.line else { return "" }
        return lines[(entry.line + 1)...entry.end].joined(separator: "\n")
    }
}
