import Foundation

/// A short-lived child process that speaks newline-delimited JSON-RPC over stdio
/// (used for `codex app-server`). One reader dispatches each response to the waiter with the
/// matching `id`; notifications are ignored. Waiters fail only after stdout reaches EOF and every
/// buffered line has been delivered, so a final response written just before exit is not lost.
public final class JSONRPCProcess: @unchecked Sendable {
    public enum Failure: Error, Sendable, CustomStringConvertible {
        case launchFailed
        case exited
        case timedOut(method: String)
        /// The server's message is kept for classification only and never printed or persisted.
        case rpcError(code: Int?, message: String)

        public var description: String {
            switch self {
            case .launchFailed: "launchFailed"
            case .exited: "exited"
            case .timedOut(let method): "timedOut(\(method))"
            case .rpcError(let code, _): "rpcError(code: \(code.map(String.init) ?? "nil"))"
            }
        }
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let lock = NSLock()
    private var nextID = 1
    private var waiters: [Int: CheckedContinuation<Result<Data, Failure>, Never>] = [:]
    private var finished = false
    private var buffer = Data()
    private static let maxBuffer = 4 * 1024 * 1024

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        if let environment { process.environment = environment }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
    }

    public func start() throws(Failure) {
        _ = ProcessRunner.ignoreSIGPIPE
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { self?.finish() } else { self?.feed(chunk) }
        }
        do { try process.run() } catch { throw .launchFailed }
    }

    public func notify(_ method: String, params: [String: Any] = [:]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Sends a request and returns its `result` object.
    public func request(_ method: String, params: [String: Any] = [:], timeout: Duration) async throws(Failure) -> Data {
        let id = lock.withLock { defer { nextID += 1 }; return nextID }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.resolve(id, with: .failure(.timedOut(method: method))) }
        }
        defer { timer.cancel() }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, Failure>, Never>) in
            let alreadyFinished = lock.withLock {
                if finished { return true }
                waiters[id] = continuation
                return false
            }
            if alreadyFinished {
                continuation.resume(returning: .failure(.exited))
            } else {
                write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            }
        }
        return try result.get()
    }

    public func stop() {
        try? stdinPipe.fileHandleForWriting.close()
        ProcessRunner.terminate(process)
        finish()
    }

    // MARK: Reading

    private func feed(_ chunk: Data) {
        let lines: [Data] = lock.withLock {
            buffer.append(chunk)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty { lines.append(Data(line)) }
            }
            if buffer.count > Self.maxBuffer { buffer.removeAll() }
            return lines
        }
        for line in lines { deliver(line) }
    }

    private func deliver(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = object["id"] as? Int
        else { return }
        if let error = object["error"] as? [String: Any] {
            resolve(id, with: .failure(.rpcError(code: error["code"] as? Int, message: error["message"] as? String ?? "")))
        } else {
            let data = (try? JSONSerialization.data(withJSONObject: object["result"] ?? [String: Any]())) ?? Data()
            resolve(id, with: .success(data))
        }
    }

    private func resolve(_ id: Int, with result: Result<Data, Failure>) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.resume(returning: result)
    }

    /// Called on stdout EOF (after all buffered data was fed) or `stop()`: fails remaining waiters.
    private func finish() {
        let pending: [CheckedContinuation<Result<Data, Failure>, Never>] = lock.withLock {
            guard !finished else { return [] }
            finished = true
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in pending { waiter.resume(returning: .failure(.exited)) }
    }

    private func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }
}
