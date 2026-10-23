import Foundation

/// Identifies a pod (and its containers) for the Files, Logs and Shell panels.
public struct PodRef: Sendable, Hashable {
    public let context: String
    public let namespace: String
    public let pod: String
    public let containers: [String]

    public init(context: String, namespace: String, pod: String, containers: [String]) {
        self.context = context
        self.namespace = namespace
        self.pod = pod
        self.containers = containers
    }
}

public struct RemoteFile: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case directory, file, symlink, other(String) }

    public var id: String { name }
    public let name: String
    public let kind: Kind
    public let size: Int64?
    public let modified: Date?
    public let permissions: String?
    public let owner: String?
    public let group: String?
    /// Symlinks pointing at directories can be navigated into.
    public var isNavigable: Bool

    public var isDirectory: Bool { kind == .directory }
}

public enum PodFileSystemError: LocalizedError {
    case noShell, noTar, notADirectory(String)

    public var errorDescription: String? {
        switch self {
        case .noShell: "This container has no shell. Browsing files needs sh (and tar for transfers) in the image; distroless images aren't supported yet."
        case .noTar: "This container has no tar, which is needed to copy folders."
        case .notADirectory(let path): "\(path) is not a directory or can't be opened."
        }
    }
}

/// Finder-style operations on a container filesystem, the same way `kubectl cp` does it:
/// `sh`, `stat`/`ls` and `tar` inside the container, streamed over `kubectl exec`.
public struct PodFileSystem: Sendable {
    public let client: KubeClient
    public let pod: PodRef
    public let container: String?

    public init(kubectl: Kubectl, pod: PodRef, container: String?) {
        client = KubeClient(kubectl: kubectl, context: pod.context)
        self.pod = pod
        self.container = container
    }

    private func execArgs(_ command: [String], stdin: Bool = false) -> [String] {
        var rest = ["exec"]
        if stdin { rest.append("-i") }
        rest.append(pod.pod)
        if let container { rest += ["--container", container] }
        return client.args(rest + ["--"] + command, namespace: pod.namespace)
    }

    private func mapError(_ error: Error) -> Error {
        guard let e = error as? ProcessError else { return error }
        let text = e.stderr
        if text.contains("\"sh\": executable file not found") || text.contains("exec: \"sh\"") { return PodFileSystemError.noShell }
        if text.contains("\"tar\": executable file not found") || text.contains("exec: \"tar\"") { return PodFileSystemError.noTar }
        return error
    }

    private func exec(_ command: [String]) async throws -> String {
        do {
            return try await client.kubectl.runString(execArgs(command))
        } catch {
            throw mapError(error)
        }
    }

    public func workingDirectory() async throws -> String {
        let dir = try await exec(["sh", "-c", "pwd"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? "/" : dir
    }

    static let listScript = #"""
    cd -- "$1" 2>/dev/null || { echo "__KUBEUI_NODIR__" >&2; exit 3; }
    if command -v stat >/dev/null 2>&1; then
      stat -c '%F/%s/%Y/%A/%U/%G/%n' -- * .[!.]* ..?* 2>/dev/null
    else
      echo '__KUBEUI_NOSTAT__'
      ls -1Ap
    fi
    echo '__KUBEUI_LINKDIRS__'
    for f in * .[!.]* ..?*; do if [ -L "$f" ] && [ -d "$f" ]; then printf '%s\n' "$f"; fi; done
    exit 0
    """#

    public func list(_ directory: String) async throws -> [RemoteFile] {
        let output: String
        do {
            output = try await exec(["sh", "-c", Self.listScript, "kubeui", directory])
        } catch let error as ProcessError where error.stderr.contains("__KUBEUI_NODIR__") {
            throw PodFileSystemError.notADirectory(directory)
        }
        return Self.parseListing(output)
    }

    static func parseListing(_ output: String) -> [RemoteFile] {
        let sections = output.components(separatedBy: "__KUBEUI_LINKDIRS__\n")
        let linkDirs = Set(sections.count > 1 ? sections[1].split(separator: "\n").map(String.init) : [])
        var lines = sections[0].split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var files: [RemoteFile] = []
        if lines.first == "__KUBEUI_NOSTAT__" {
            lines.removeFirst()
            for line in lines where line != "./" && line != "../" {
                let isDir = line.hasSuffix("/")
                let name = isDir ? String(line.dropLast()) : line
                files.append(RemoteFile(name: name, kind: isDir ? .directory : .file, size: nil, modified: nil,
                                        permissions: nil, owner: nil, group: nil, isNavigable: isDir || linkDirs.contains(name)))
            }
            return files
        }
        for line in lines {
            let parts = line.split(separator: "/", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 7 else { continue }
            let kind: RemoteFile.Kind = switch parts[0] {
            case "directory": .directory
            case "symbolic link": .symlink
            case "regular file", "regular empty file": .file
            default: .other(parts[0])
            }
            files.append(RemoteFile(
                name: parts[6],
                kind: kind,
                size: Int64(parts[1]),
                modified: Double(parts[2]).map { Date(timeIntervalSince1970: $0) },
                permissions: parts[3],
                owner: parts[4],
                group: parts[5],
                isNavigable: kind == .directory || linkDirs.contains(parts[6])
            ))
        }
        return files
    }

    public func makeDirectory(_ path: String) async throws {
        _ = try await exec(["mkdir", "-p", "--", path])
    }

    public func remove(_ paths: [String]) async throws {
        _ = try await exec(["rm", "-rf", "--"] + paths)
    }

    public func rename(_ from: String, to: String) async throws {
        _ = try await exec(["mv", "--", from, to])
    }

    /// Uploads local files/folders into `directory`. `progress(sent, total)` reports file bytes.
    public func upload(_ urls: [URL], to directory: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let entries = try TarWriter.entries(for: urls)
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        progress(0, total)
        do {
            try await client.kubectl.run(execArgs(["tar", "-xf", "-", "-C", directory], stdin: true)) { handle in
                try TarWriter.write(entries, to: { try handle.write(contentsOf: $0) }, progress: { progress($0, total) })
            }
        } catch {
            let mapped = mapError(error)
            // Images without tar can still take plain files.
            guard case PodFileSystemError.noTar = mapped, entries.allSatisfy({ !$0.isDirectory && $0.symlinkTarget == nil }) else { throw mapped }
            var sent: Int64 = 0
            for entry in entries {
                let target = (directory as NSString).appendingPathComponent(entry.archivePath)
                let base = sent
                try await client.kubectl.run(execArgs(["sh", "-c", "cat > \"$1\"", "kubeui", target], stdin: true)) { handle in
                    let reader = try FileHandle(forReadingFrom: entry.url)
                    defer { try? reader.close() }
                    var done: Int64 = 0
                    while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                        try handle.write(contentsOf: chunk)
                        done += Int64(chunk.count)
                        progress(base + done, total)
                    }
                }
                sent += entry.size
            }
        }
    }

    /// Downloads `path` (file or folder) and returns the local URL it was saved as. An existing item at
    /// `destination` is never overwritten; a numbered name is used instead, as Finder does.
    @discardableResult
    public func download(_ path: String, to destination: URL, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: staging) }

        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let pipe = Pipe()
        async let extract = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", "-", "-C", staging.path], input: .pipe(pipe))
        do {
            let writer = pipe.fileHandleForWriting
            let received = Counter()
            try await client.kubectl.run(execArgs(["tar", "-cf", "-", "-C", parent.isEmpty ? "/" : parent, name])) { chunk in
                try writer.write(contentsOf: chunk)
                progress(received.add(Int64(chunk.count)))
            }
            try writer.close()
        } catch {
            try? pipe.fileHandleForWriting.close()
            _ = try? await extract
            throw mapError(error)
        }
        let result = try await extract
        guard result.status == 0 else {
            throw ProcessError(command: "tar", status: result.status, stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        let target = Self.uniqueURL(destination)
        try fm.moveItem(at: staging.appendingPathComponent(name), to: target)
        return target
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for i in 2... {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func add(_ n: Int64) -> Int64 {
        lock.withLock {
            value += n
            return value
        }
    }
}
