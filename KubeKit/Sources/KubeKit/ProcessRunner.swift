import Foundation

public struct ProcessError: LocalizedError, Sendable {
    public let command: String
    public let status: Int32
    public let stderr: String

    public var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "\(command) exited with status \(status)" : message
    }
}

/// Blocking-IO process plumbing, run off the cooperative pool so long transfers don't starve it.
enum ProcessRunner {
    enum Input: Sendable {
        case none
        case data(Data)
        /// Called on a background thread; write to the handle, it is closed afterwards.
        case writer(@Sendable (FileHandle) throws -> Void)
        /// Read end handed to the child; the caller owns the write end.
        case pipe(Pipe)
    }

    struct Output: Sendable {
        var stdout: Data
        var stderr: Data
        var status: Int32
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let process = Process()
        var stdout = Data()
        var stderr = Data()
        var failure: Error?

        func record(_ error: Error) {
            lock.withLock { if failure == nil { failure = error } }
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs to completion. `onStdout` receives chunks as they arrive; when nil, stdout is collected.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        input: Input = .none,
        onStdout: (@Sendable (Data) throws -> Void)? = nil
    ) async throws -> Output {
        _ = ignoreSigpipe
        let state = State()
        let process = state.process
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        switch input {
        case .none: process.standardInput = FileHandle.nullDevice
        case .pipe(let pipe): process.standardInput = pipe
        default: process.standardInput = inPipe
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        cont.resume(throwing: error)
                        return
                    }
                    running.insert(process)
                    defer { running.remove(process) }
                    if state.lock.withLock({ state.failure != nil }) { process.terminate() }
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        let data = (try? errPipe.fileHandleForReading.readToEnd()) ?? nil
                        state.lock.withLock { state.stderr = data ?? Data() }
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global().async {
                        let fd = outPipe.fileHandleForReading.fileDescriptor
                        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                        do {
                            // POSIX read returns as soon as any bytes arrive; FileHandle.read(upToCount:)
                            // waits for the full count, which stalls streams like `logs -f`.
                            while true {
                                let n = read(fd, &buffer, buffer.count)
                                if n < 0, errno == EINTR { continue }
                                if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                                if n == 0 { break }
                                let chunk = Data(buffer[0..<n])
                                if let onStdout {
                                    try onStdout(chunk)
                                } else {
                                    state.lock.withLock { state.stdout.append(chunk) }
                                }
                            }
                        } catch {
                            state.record(error)
                        }
                        group.leave()
                    }
                    switch input {
                    case .none, .pipe:
                        break
                    case .data(let data):
                        try? inPipe.fileHandleForWriting.write(contentsOf: data)
                        try? inPipe.fileHandleForWriting.close()
                    case .writer(let write):
                        do {
                            try write(inPipe.fileHandleForWriting)
                        } catch {
                            state.record(error)
                        }
                        try? inPipe.fileHandleForWriting.close()
                    }
                    group.wait()
                    process.waitUntilExit()
                    let (failure, out, err) = state.lock.withLock { (state.failure, state.stdout, state.stderr) }
                    if let failure {
                        // The child's own message usually explains a broken pipe better than EPIPE does.
                        let message = String(decoding: err, as: UTF8.self)
                        if !(failure is CancellationError), process.terminationStatus != 0, !message.isEmpty {
                            cont.resume(throwing: ProcessError(command: executable.lastPathComponent, status: process.terminationStatus, stderr: message))
                        } else {
                            cont.resume(throwing: failure)
                        }
                        return
                    }
                    cont.resume(returning: Output(stdout: out, stderr: err, status: process.terminationStatus))
                }
            }
        } onCancel: {
            state.record(CancellationError())
        }
    }

    private static let running = ProcessSet()

    /// Stops every child (watches, log follows, transfers), e.g. when the app quits.
    static func terminateAll() { running.terminateAll() }

    // A child dying while we write to its stdin must surface as EPIPE, not kill the app.
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()
}

private final class ProcessSet: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [ObjectIdentifier: Process] = [:]

    func insert(_ p: Process) {
        lock.withLock { byID[ObjectIdentifier(p)] = p }
    }

    func remove(_ p: Process) {
        lock.withLock { byID[ObjectIdentifier(p)] = nil }
    }

    func terminateAll() {
        for p in lock.withLock({ Array(byID.values) }) where p.isRunning { p.terminate() }
    }
}
