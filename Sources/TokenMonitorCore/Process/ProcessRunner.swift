import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Sendable {
    case launchFailed(String)
}

/// Runs a child process without a shell, drains stdout/stderr concurrently with a size cap,
/// and terminates (then kills) it when the timeout expires or the calling task is cancelled.
///
/// Every wait is bounded: stdin is written off the calling thread, and after the child exits we wait
/// only briefly for pipe EOF (a grandchild that inherited stdout could otherwise hold it open forever).
public enum ProcessRunner {
    static let drainGrace: Duration = .milliseconds(500)

    /// Writing to a child that already exited raises SIGPIPE, which would kill the app.
    static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: Duration,
        maxOutputBytes: Int = 512 * 1024
    ) async throws -> ProcessResult {
        _ = ignoreSIGPIPE
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        if let environment { process.environment = environment }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = stdin.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let out = CappedBuffer(limit: maxOutputBytes)
        let err = CappedBuffer(limit: maxOutputBytes)
        outPipe.fileHandleForReading.readabilityHandler = { handle in out.consume(handle.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { handle in err.consume(handle.availableData) }

        let timedOut = Flag()
        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                    return
                }
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    guard process.isRunning else { return }
                    timedOut.set()
                    terminate(process)
                }
                if let inPipe, let stdin {
                    let writer = inPipe.fileHandleForWriting
                    DispatchQueue.global().async {
                        try? writer.write(contentsOf: stdin)
                        try? writer.close()
                    }
                }
            }
        } onCancel: {
            terminate(process)
        }

        let deadline = ContinuousClock.now + drainGrace
        while !(out.reachedEOF && err.reachedEOF), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for pipe in [outPipe, errPipe] {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }
        return ProcessResult(exitCode: exitCode, stdout: out.data, stderr: err.data, timedOut: timedOut.isSet)
    }

    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

final class CappedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var eof = false
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    /// An empty chunk from a readability handler means EOF.
    func consume(_ chunk: Data) {
        lock.withLock {
            if chunk.isEmpty { eof = true; return }
            let room = limit - storage.count
            if room > 0 { storage.append(chunk.prefix(room)) }
        }
    }

    var data: Data { lock.withLock { storage } }
    var reachedEOF: Bool { lock.withLock { eof } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
