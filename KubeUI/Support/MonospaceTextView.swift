import AppKit
import SwiftUI

/// Owns an NSTextView so models can append large amounts of text without SwiftUI diffing it.
final class TextViewController {
    let textView: NSTextView
    let scrollView: NSScrollView
    /// Keeps memory bounded for long-running log follows.
    var maxCharacters = 4_000_000
    /// Styles complete lines; when set, a trailing partial line waits for the rest of it.
    var lineStyler: ((String, NSFont) -> NSAttributedString)?
    private var partialLine = ""

    init() {
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        setWraps(false)
    }

    func setWraps(_ wraps: Bool) {
        let container = textView.textContainer!
        container.widthTracksTextView = wraps
        textView.isHorizontallyResizable = !wraps
        scrollView.hasHorizontalScroller = !wraps
        if wraps {
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }

    /// Replaces the text, styled with `lineStyler` when set.
    func setStyled(_ text: String) {
        guard let lineStyler, let font = textView.font else { return setText(text) }
        textView.textStorage?.setAttributedString(lineStyler(text, font))
        textView.scrollToBeginningOfDocument(nil)
    }

    func setText(_ text: String) {
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }

    func append(_ text: String) {
        guard let storage = textView.textStorage, let font = textView.font else { return }
        let clip = scrollView.contentView
        let atBottom = clip.bounds.maxY >= (textView.frame.height - 20)
        if let lineStyler {
            let combined = partialLine + text
            guard let newline = combined.lastIndex(of: "\n") else {
                partialLine = combined
                return
            }
            partialLine = String(combined[combined.index(after: newline)...])
            storage.append(lineStyler(String(combined[...newline]), font))
        } else {
            storage.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        }
        if storage.length > maxCharacters {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - maxCharacters * 3 / 4))
        }
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    /// Writes out a held-back partial line, e.g. when the stream ends.
    func flush() {
        guard !partialLine.isEmpty else { return }
        let line = partialLine
        partialLine = ""
        let styler = lineStyler
        lineStyler = nil
        append(line)
        lineStyler = styler
    }

    func clear() {
        textView.string = ""
        partialLine = ""
    }
}

struct MonospaceTextView: NSViewRepresentable {
    let controller: TextViewController

    func makeNSView(context: Context) -> NSScrollView { controller.scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
