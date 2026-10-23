import AppKit
import KubeKit
import SwiftUI

/// Git status of the linked clone: diff, then commit + push (or a PR), which starts rollout tracking.
struct ChangesView: View {
    let model: ArgoAppModel
    @State private var message = ""
    @State private var diffView = TextViewController()
    @State private var prBranch: String?
    @State private var confirmDiscard = false

    var body: some View {
        if model.repo == nil {
            ContentUnavailableView("Repository Not Linked", systemImage: "externaldrive.badge.questionmark",
                                   description: Text("Link your local clone from the Source card above."))
        } else {
            VStack(spacing: 0) {
                statusBar
                Divider()
                if model.changes.isEmpty {
                    ContentUnavailableView("No Local Changes", systemImage: "checkmark.circle",
                                           description: Text("Edit configuration to change this app. Changes appear here for review."))
                } else {
                    HSplitView {
                        List(model.changes) { change in
                            HStack {
                                Text(statusLabel(change.status))
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(change.status == "??" ? .green : .orange)
                                    .frame(width: 18)
                                Text(change.path).lineLimit(1).truncationMode(.head).help(change.path)
                            }
                        }
                        .frame(minWidth: 200, idealWidth: 280, maxWidth: 420)
                        MonospaceTextView(controller: diffView).frame(minWidth: 300)
                    }
                    Divider()
                    commitBar
                }
            }
            .onAppear {
                diffView.lineStyler = DiffHighlighter.style
                diffView.setStyled(model.diff)
                if message.isEmpty { message = suggestedMessage }
                Task { await model.refreshGit(fetch: false) }
            }
            .onChange(of: model.diff) {
                diffView.setStyled(model.diff)
                message = suggestedMessage
            }
            .alert("New Branch for Pull Request", isPresented: Binding(get: { prBranch != nil }, set: { if !$0 { prBranch = nil } })) {
                TextField("Branch", text: Binding(get: { prBranch ?? "" }, set: { prBranch = $0 }))
                Button("Push & Open PR") {
                    let branch = prBranch ?? ""
                    Task { await model.commitToPullRequest(message, branchName: branch) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Commits to a new branch, pushes it and opens GitHub's pull request page against \(model.trackedBranch).")
            }
            .confirmationDialog("Discard all local changes?", isPresented: $confirmDiscard) {
                Button("Discard", role: .destructive) { Task { await model.discardChanges() } }
            } message: {
                Text("Restores \(model.changes.count) file(s) in \(model.repo?.root.lastPathComponent ?? "the repo") to the last commit.")
            }
        }
    }

    private var statusBar: some View {
        PanelBar {
            Label(model.branch ?? "", systemImage: "arrow.triangle.branch")
                .labelStyle(.titleAndIcon)
                .font(.callout)
            if let ab = model.aheadBehind {
                Text("↑\(ab.ahead) ↓\(ab.behind)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .help("Commits ahead of / behind the upstream branch")
            }
            if let branch = model.branch, branch != model.trackedBranch, model.trackedBranch != "HEAD" {
                Label("Argo tracks \(model.trackedBranch)", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon).font(.callout).foregroundStyle(.orange)
            }
            Spacer()
            if let busy = model.busy { ProgressView().controlSize(.small); Text(busy + "…").font(.callout) }
            Button { Task { await model.pull() } } label: { Label("Pull", systemImage: "arrow.down.circle") }
                .help("Pull (fast-forward only)")
            Button { Task { await model.refreshGit(fetch: true) } } label: { Label("Fetch", systemImage: "arrow.clockwise") }
                .help("Fetch and refresh status")
            Button { confirmDiscard = true } label: { Label("Discard", systemImage: "arrow.uturn.backward") }
                .disabled(model.changes.isEmpty)
                .help("Discard local changes")
        }
    }

    private var commitBar: some View {
        HStack(spacing: 8) {
            TextField("Commit message", text: $message)
                .textFieldStyle(.roundedBorder)
            if (model.aheadBehind?.behind ?? 0) > 0 {
                Text("Pull first").font(.callout).foregroundStyle(.orange)
            }
            Button("Commit & Push") { Task { await model.commitAndPush(message) } }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(message.isEmpty || model.busy != nil)
                .help("Commit the changes and push to \(model.branch ?? "the current branch"); Argo CD then rolls it out")
            Button("Push as PR…") { prBranch = "kubeui/\(model.application.name)-\(Self.stamp())" }
                .disabled(message.isEmpty || model.busy != nil)
                .help("Commit to a new branch and open a pull request")
        }
        .padding(10)
        .background(.bar)
    }

    /// "demo-ops-app-tst: set LOG_LEVEL, APP_FLAG" from the env keys touched in the diff.
    private var suggestedMessage: String {
        let keys = model.diff.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("+"), !line.hasPrefix("+++") else { return nil }
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let colon = body.firstIndex(of: ":") else { return nil }
            let key = String(body[..<colon])
            return key.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" } && !key.isEmpty ? key : nil
        }
        let unique = keys.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let summary = unique.isEmpty ? "update configuration" : "set " + unique.prefix(3).joined(separator: ", ") + (unique.count > 3 ? "…" : "")
        return "\(model.application.name): \(summary)"
    }

    private func statusLabel(_ status: String) -> String {
        status == "??" ? "A" : status.trimmingCharacters(in: .whitespaces).prefix(1).description
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }
}

/// Colours unified diff output.
enum DiffHighlighter {
    static func style(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, range, _, _ in
            guard let line else { return }
            let color: NSColor? = switch true {
            case line.hasPrefix("+++"), line.hasPrefix("---"), line.hasPrefix("diff "), line.hasPrefix("index "): .secondaryLabelColor
            case line.hasPrefix("@@"): .systemPurple
            case line.hasPrefix("+"): .systemGreen
            case line.hasPrefix("-"): .systemRed
            default: nil
            }
            if let color { result.addAttribute(.foregroundColor, value: color, range: range) }
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                result.addAttribute(.backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.12), range: range)
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                result.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.12), range: range)
            }
        }
        return result
    }
}
