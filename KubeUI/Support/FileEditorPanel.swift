import AppKit
import SwiftUI

/// A YAML file (or read-only YAML text) open for editing in the bottom panel.
@Observable
final class FileEditorModel {
    let title: String
    let file: URL?
    let readOnlyReason: String?
    let controller = TextViewController()
    private(set) var isDirty = false
    private(set) var error: String?
    private let readOnlyText: String
    private let onSave: () -> Void

    /// `file` nil shows `text` read-only, with `readOnlyReason` explaining why.
    init(title: String, file: URL?, text: String = "", readOnlyReason: String? = nil, onSave: @escaping () -> Void = {}) {
        self.title = title
        self.file = file
        self.readOnlyText = text
        self.readOnlyReason = file == nil ? (readOnlyReason ?? "Read-only") : nil
        self.onSave = onSave
        controller.lineStyler = YAMLHighlighter.style
        if file != nil {
            controller.makeEditable(restyle: YAMLHighlighter.apply)
            controller.onEdit = { [weak self] in self?.isDirty = true }
        }
        load()
    }

    var id: String { "editor:" + (file?.path ?? title) }

    func load() {
        if let file {
            // A missing file is fine: ignoreMissingValueFiles layers are created on first save.
            controller.setStyled((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        } else {
            controller.setStyled(readOnlyText)
        }
        isDirty = false
    }

    func save() {
        guard let file, isDirty else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try controller.textView.string.write(to: file, atomically: true, encoding: .utf8)
            isDirty = false
            error = nil
            onSave()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct FileEditorPanel: View {
    let model: FileEditorModel

    var body: some View {
        VStack(spacing: 0) {
            MonospaceTextView(controller: model.controller)
            Divider()
            PanelBar {
                Image(systemName: model.file == nil ? "lock" : "doc.text").foregroundStyle(.secondary)
                Text(model.title).font(.callout).lineLimit(1).truncationMode(.head)
                if model.isDirty { Text("Edited").font(.caption).foregroundStyle(.orange) }
                if let reason = model.readOnlyReason { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                if let file = model.file {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Label("Reveal in Finder", systemImage: "folder") }
                        .help("Reveal in Finder")
                    Button { model.load() } label: { Label("Revert", systemImage: "arrow.uturn.backward") }
                        .disabled(!model.isDirty)
                        .help("Discard unsaved edits")
                    Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                        .keyboardShortcut("s")
                        .disabled(!model.isDirty)
                        .help("Save (⌘S)")
                }
            }
        }
    }
}
