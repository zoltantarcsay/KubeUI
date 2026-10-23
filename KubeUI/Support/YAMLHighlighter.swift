import AppKit

/// Colours YAML (and `kubectl describe`'s similar `Key: value` output) line by line.
enum YAMLHighlighter {
    private static let comment = regex(#"(^|\s)#.*$"#)
    private static let key = regex(#"^(\s*(?:-\s+)?)((?:"[^"]*"|'[^']*'|[^\s#'"][^:#]*?)):(?=\s|$)"#)
    private static let dash = regex(#"^\s*-(?=\s|$)"#)
    private static let docMarker = regex(#"^(---|\.\.\.)\s*$"#)
    private static let quoted = regex(#""(?:[^"\\]|\\.)*"|'(?:[^']|'')*'"#)
    private static let number = regex(#"^[-+]?(\d+(\.\d+)?([eE][-+]?\d+)?|0x[0-9a-fA-F]+|\.inf|\.nan)$"#)
    private static let keyword = regex(#"^(true|false|yes|no|on|off|null|~|True|False|TRUE|FALSE|Null|NULL)$"#)
    private static let anchor = regex(#"[&*][A-Za-z0-9_-]+"#)

    static func style(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        apply(to: result, font: font)
        return result
    }

    /// Restyles `storage` in place (keeps the selection when used on a live text view).
    static func apply(to storage: NSMutableAttributedString, font: NSFont) {
        let text = storage.string
        let ns = text as NSString
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: NSRange(location: 0, length: ns.length))
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            func color(_ range: NSRange, _ c: NSColor) { storage.addAttribute(.foregroundColor, value: c, range: range) }
            if let m = docMarker.firstMatch(in: text, range: line) { return color(m.range, .secondaryLabelColor) }
            var valueStart = line.location
            if let m = key.firstMatch(in: text, range: line) {
                color(m.range(at: 2), .systemBlue)
                valueStart = NSMaxRange(m.range)
            } else if let m = dash.firstMatch(in: text, range: line) {
                valueStart = NSMaxRange(m.range)
            }
            if let m = dash.firstMatch(in: text, range: line) { color(m.range, .secondaryLabelColor) }
            // The value: everything after "key:" (or "- ") up to a comment.
            var valueEnd = NSMaxRange(line)
            if let c = comment.firstMatch(in: text, range: NSRange(location: valueStart, length: NSMaxRange(line) - valueStart)),
               quoted.firstMatch(in: text, range: NSRange(location: valueStart, length: NSMaxRange(line) - valueStart)).map({ NSMaxRange($0.range) <= c.range.location || $0.range.location > c.range.location }) ?? true {
                color(c.range, .secondaryLabelColor)
                valueEnd = c.range.location
            }
            let valueRange = NSRange(location: valueStart, length: max(0, valueEnd - valueStart))
            let raw = ns.substring(with: valueRange)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let lead = (raw as NSString).range(of: trimmed).location
            let trimmedRange = NSRange(location: valueRange.location + lead, length: (trimmed as NSString).length)
            if trimmed.hasPrefix("|") || trimmed.hasPrefix(">") {
                color(trimmedRange, .systemOrange)
            } else if number.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil {
                color(trimmedRange, .systemPurple)
            } else if keyword.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil {
                color(trimmedRange, .systemPink)
            } else {
                color(trimmedRange, .systemRed.blended(withFraction: 0.25, of: .textColor) ?? .systemRed)
            }
            for m in anchor.matches(in: text, range: valueRange) { color(m.range, .systemOrange) }
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}
