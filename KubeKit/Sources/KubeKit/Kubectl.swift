import Foundation

public enum KubectlLocateError: LocalizedError {
    case notFound(searchPath: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            "kubectl was not found. Install it (brew install kubectl) or set its path in Settings.\nSearched: \(path)"
        }
    }
}

/// A resolved `kubectl` binary plus the environment it (and its exec auth plugins) should run with.
public struct Kubectl: Sendable {
    public let executable: URL
    public let environment: [String: String]

    public init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    /// GUI apps launched from Finder get a minimal PATH, so borrow the user's login shell environment.
    public static func resolve(overridePath: String? = nil) async throws -> Kubectl {
        var env = await loginShellEnvironment() ?? ProcessInfo.processInfo.environment
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in fallbacks where !path.contains(dir) { path.append(dir) }
        env["PATH"] = path.joined(separator: ":")

        let fm = FileManager.default
        if let overridePath, !overridePath.isEmpty {
            let expanded = (overridePath as NSString).expandingTildeInPath
            guard fm.isExecutableFile(atPath: expanded) else { throw KubectlLocateError.notFound(searchPath: expanded) }
            return Kubectl(executable: URL(fileURLWithPath: expanded), environment: env)
        }
        for dir in path {
            let candidate = (dir as NSString).appendingPathComponent("kubectl")
            if fm.isExecutableFile(atPath: candidate) {
                return Kubectl(executable: URL(fileURLWithPath: candidate), environment: env)
            }
        }
        throw KubectlLocateError.notFound(searchPath: env["PATH"] ?? "")
    }

    static func loginShellEnvironment() async -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__KUBEUI_ENV__"
        let task = Task {
            try await ProcessRunner.run(
                URL(fileURLWithPath: shell),
                ["-l", "-i", "-c", "printf '\(marker)'; /usr/bin/env -0"]
            )
        }
        // An interactive shell with a misbehaving rc file must not hang app startup.
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            task.cancel()
        }
        defer { timeout.cancel() }
        guard let output = try? await task.value,
              let text = String(data: output.stdout, encoding: .utf8),
              let range = text.range(of: marker) else { return nil }
        var env: [String: String] = [:]
        for entry in text[range.upperBound...].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }

    /// Runs kubectl and returns stdout, throwing with kubectl's stderr on failure.
    public func run(_ arguments: [String], input: Data? = nil) async throws -> Data {
        let output = try await ProcessRunner.run(
            executable, arguments, environment: environment, input: input.map { .data($0) } ?? .none
        )
        guard output.status == 0 else { throw error(arguments, output) }
        return output.stdout
    }

    /// Terminates all running kubectl children; call when the app quits so watches don't linger.
    public static func terminateAll() { ProcessRunner.terminateAll() }

    public func runString(_ arguments: [String]) async throws -> String {
        String(decoding: try await run(arguments), as: UTF8.self)
    }

    /// Streams `write`'s output into kubectl's stdin (used for uploads).
    public func run(_ arguments: [String], stdinWriter: @escaping @Sendable (FileHandle) throws -> Void) async throws {
        let output = try await ProcessRunner.run(executable, arguments, environment: environment, input: .writer(stdinWriter))
        guard output.status == 0 else { throw error(arguments, output) }
    }

    /// Hands stdout to `onChunk` as it arrives (used for downloads, logs and watches).
    public func run(_ arguments: [String], onStdout: @escaping @Sendable (Data) throws -> Void) async throws {
        let output = try await ProcessRunner.run(executable, arguments, environment: environment, onStdout: onStdout)
        guard output.status == 0 else { throw error(arguments, output) }
    }

    public func stream(_ arguments: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(arguments) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func error(_ arguments: [String], _ output: ProcessRunner.Output) -> ProcessError {
        ProcessError(
            command: "kubectl " + arguments.prefix(3).joined(separator: " "),
            status: output.status,
            stderr: String(decoding: output.stderr, as: UTF8.self)
        )
    }
}
