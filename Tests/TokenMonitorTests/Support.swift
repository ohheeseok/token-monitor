import Foundation
import TokenMonitorCore

enum Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
}

let referenceNow = Date(timeIntervalSince1970: 1_793_600_000) // 2026-11-02T05:33:20Z

func date(_ iso: String) -> Date { try! Date(iso, strategy: .iso8601) }

/// Returns scripted HTTP responses in order and records the requests it received.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, [String: String], Data)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, [String: String], Data)]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, headers, body) = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? (500, [:], Data()) : responses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (body, response)
    }

    var authorizationHeaders: [String?] { lock.withLock { requests.map { $0.value(forHTTPHeaderField: "Authorization") } } }
}

/// A provider whose fetch blocks until the test releases it, so tests can interleave reconfiguration.
actor GatedProvider: UsageProvider {
    private var continuation: CheckedContinuation<Void, Never>?
    private var result: Result<UsageSnapshot, ProviderFailure>
    private(set) var calls = 0

    init(_ result: Result<UsageSnapshot, ProviderFailure>) { self.result = result }

    func fetch(now: Date) async throws(ProviderFailure) -> UsageSnapshot {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return try result.get()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    var isWaiting: Bool { continuation != nil }
}

struct ImmediateProvider: UsageProvider {
    let result: Result<UsageSnapshot, ProviderFailure>
    func fetch(now: Date) async throws(ProviderFailure) -> UsageSnapshot { try result.get() }
}
