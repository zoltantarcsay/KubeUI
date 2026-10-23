import Foundation

/// A local clone, driven through the user's own `git` so their credentials, SSH agent and hooks apply.
public struct GitRepo: Sendable {
    public struct Change: Sendable, Hashable, Identifiable {
        public var id: String { path }
        /// Two-letter porcelain status, e.g. " M", "??", "A ".
        public let status: String
        public let path: String
    }

    public struct Commit: Sendable, Hashable {
        public let sha: String
        public let subject: String
        public var short: String { String(sha.prefix(7)) }
    }

    public let root: URL
    let git: URL
    let environment: [String: String]

    /// Opens the repository containing `url`, using git from the same PATH as kubectl.
    public static func open(_ url: URL, environment: [String: String]) async throws -> GitRepo {
        var env = environment
        // Never block on an interactive credential prompt; fail with git's message instead.
        env["GIT_TERMINAL_PROMPT"] = "0"
        let path = (env["PATH"] ?? "/usr/bin").split(separator: ":").map(String.init)
        let gitPath = path.map { ($0 as NSString).appendingPathComponent("git") }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
        let probe = GitRepo(root: url, git: URL(fileURLWithPath: gitPath), environment: env)
        let top = try await probe.run(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return GitRepo(root: URL(fileURLWithPath: top), git: probe.git, environment: env)
    }

    @discardableResult
    func run(_ arguments: [String]) async throws -> String {
        let output = try await ProcessRunner.run(git, ["-C", root.path] + arguments, environment: environment)
        guard output.status == 0 else {
            throw ProcessError(command: "git " + (arguments.first ?? ""), status: output.status, stderr: String(decoding: output.stderr, as: UTF8.self))
        }
        return String(decoding: output.stdout, as: UTF8.self)
    }

    public func remoteURL() async throws -> String {
        try await run(["remote", "get-url", "origin"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func currentBranch() async throws -> String {
        try await run(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func head() async throws -> Commit {
        let parts = try await run(["log", "-1", "--format=%H%x00%s"]).trimmingCharacters(in: .newlines).split(separator: "\0", maxSplits: 1)
        return Commit(sha: String(parts.first ?? ""), subject: parts.count > 1 ? String(parts[1]) : "")
    }

    public func status() async throws -> [Change] {
        let out = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        var changes: [Change] = []
        var entries = out.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            guard entry.count > 3 else { continue }
            let status = String(entry.prefix(2))
            changes.append(Change(status: status, path: String(entry.dropFirst(3))))
            // Renames carry the original path as the next entry.
            if status.hasPrefix("R") || status.hasPrefix("C") { _ = entries.next() }
        }
        return changes
    }

    /// Unified diff of the working tree against HEAD, untracked files included.
    public func diff(_ paths: [String] = []) async throws -> String {
        let tracked = try await run(["diff", "HEAD", "--"] + paths)
        let untracked = try await status().filter { $0.status == "??" && (paths.isEmpty || paths.contains($0.path)) }
        var extra = ""
        for change in untracked {
            // `diff --no-index` exits 1 when files differ, which is the normal case here.
            let output = try await ProcessRunner.run(git, ["-C", root.path, "diff", "--no-index", "--", "/dev/null", change.path], environment: environment)
            extra += String(decoding: output.stdout, as: UTF8.self)
        }
        return tracked + extra
    }

    /// Commits ahead of / behind the upstream, after fetching it. nil without an upstream.
    public func aheadBehind(fetch: Bool) async throws -> (ahead: Int, behind: Int)? {
        if fetch { try await run(["fetch", "--quiet"]) }
        guard let out = try? await run(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]) else { return nil }
        let n = out.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        return n.count == 2 ? (n[0], n[1]) : nil
    }

    public func pull() async throws {
        try await run(["pull", "--ff-only"])
    }

    public func commit(_ message: String, paths: [String]) async throws -> Commit {
        try await run(["add", "--"] + paths)
        try await run(["commit", "-m", message, "--"] + paths)
        return try await head()
    }

    /// Pushes the current branch, creating its upstream on first push.
    public func push() async throws {
        try await run(["push", "--set-upstream", "origin", "HEAD"])
    }

    public func createBranch(_ name: String) async throws {
        try await run(["switch", "-c", name])
    }

    public func switchBranch(_ name: String) async throws {
        try await run(["switch", name])
    }

    /// Restores files to HEAD (or deletes them if untracked).
    public func discard(_ changes: [Change]) async throws {
        let tracked = changes.filter { $0.status != "??" }.map(\.path)
        let untracked = changes.filter { $0.status == "??" }.map(\.path)
        if !tracked.isEmpty { try await run(["restore", "--staged", "--worktree", "--"] + tracked) }
        for path in untracked { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
    }

    /// GitHub "compare" page for opening a pull request from `branch`, when origin is on GitHub.
    public static func pullRequestURL(remote: String, branch: String, base: String) -> URL? {
        guard let slug = githubSlug(remote) else { return nil }
        return URL(string: "https://github.com/\(slug)/compare/\(base)...\(branch)?expand=1")
    }

    /// "owner/repo" for GitHub remotes in https or ssh form.
    public static func githubSlug(_ remote: String) -> String? {
        var s = remote
        for prefix in ["https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
            return s.isEmpty ? nil : s
        }
        return nil
    }

    /// Compares repo URLs ignoring scheme, credentials, `.git` and trailing slashes.
    public static func sameRepo(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b)
    }

    static func normalize(_ url: String) -> String {
        var s = url.lowercased().trimmingCharacters(in: .whitespaces)
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        // Drop "user[:token]@" in front of the host.
        if let at = s.firstIndex(of: "@"), !s[..<at].contains("/") { s = String(s[s.index(after: at)...]) }
        s = s.replacingOccurrences(of: ":", with: "/")
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }
}
