import AppKit

/// Colours common log layouts (Spring Boot/Logback, log4j, Go, plain text) line by line:
/// timestamp, level, [thread], logger, key=value pairs and exceptions/stack frames.
enum LogHighlighter {
    private static let timestamp = regex(#"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"#)
    private static let level = regex(#"\b(?:ERROR|FATAL|SEVERE|WARN(?:ING)?|INFO|DEBUG|TRACE)\b"#)
    private static let thread = regex(#"\[[^\]\n]{1,80}\]"#)
    private static let logger = regex(#"\b(?:[a-zA-Z_$][\w$]*\.){2,}[A-Za-z_$][\w$]*\b"#)
    private static let keyValue = regex(#"\b([\w.-]+)="#)
    private static let exception = regex(#"\b[\w.$]*(?:Exception|Error|Throwable)\b|^Caused by:"#)
    private static let stackFrame = regex(#"^\s+(?:at |\.\.\. \d+ more)"#)

    static func style(_ block: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: block, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        let text = block as NSString
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            func color(_ range: NSRange, _ color: NSColor) {
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
            if stackFrame.firstMatch(in: block, range: line) != nil {
                color(line, .systemRed.withAlphaComponent(0.75))
                return
            }
            var cursor = line.location
            if let m = timestamp.firstMatch(in: block, range: line) {
                color(m.range, .secondaryLabelColor)
                cursor = NSMaxRange(m.range)
            }
            if let m = level.firstMatch(in: block, range: NSRange(location: cursor, length: min(40, NSMaxRange(line) - cursor))) {
                let word = text.substring(with: m.range)
                color(m.range, levelColor(word))
                if word == "ERROR" || word == "FATAL" || word == "SEVERE" { result.addAttribute(.font, value: bold, range: m.range) }
                cursor = NSMaxRange(m.range)
            }
            let rest = NSRange(location: cursor, length: NSMaxRange(line) - cursor)
            // Only brackets and the logger right after the level, so message text keeps its own colours.
            var head = rest
            for m in thread.matches(in: block, range: rest) where m.range.location - head.location <= 2 {
                color(m.range, .systemPurple)
                head = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
            }
            if let m = logger.firstMatch(in: block, range: head), m.range.location - head.location <= 2 {
                color(m.range, .systemTeal)
            }
            for m in keyValue.matches(in: block, range: rest) {
                color(m.range(at: 1), .systemIndigo)
            }
            for m in exception.matches(in: block, range: line) {
                color(m.range, .systemRed)
            }
        }
        return result
    }

    private static func levelColor(_ level: String) -> NSColor {
        switch level {
        case "ERROR", "FATAL", "SEVERE": .systemRed
        case "WARN", "WARNING": .systemOrange
        case "INFO": .systemGreen
        default: .secondaryLabelColor
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}
