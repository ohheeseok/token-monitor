import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral session: no disk cache, no cookies, nothing persisted between requests.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

enum HTTPStatus {
    /// Maps non-2xx responses to provider failures. 401 is handled by callers that can re-read credentials.
    static func failure(for response: HTTPURLResponse, now: Date) -> ProviderFailure {
        switch response.statusCode {
        case 401: .expiredCredentials
        case 403: .forbidden("HTTP 403")
        case 429: .rateLimited(retryAt: retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now))
        default: .server(status: response.statusCode)
        }
    }

    /// `Retry-After` is either delta-seconds or an HTTP date.
    static func retryAfter(_ value: String?, now: Date) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return now.addingTimeInterval(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    static func networkFailure(_ error: Error) -> ProviderFailure {
        if let urlError = error as? URLError, urlError.code == .timedOut { return .timedOut }
        return .network((error as? URLError)?.code.rawValue.description ?? "request failed")
    }
}
