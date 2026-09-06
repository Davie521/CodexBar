// The endpoint and request headers follow upstream CodexOAuthUsageFetcher (MIT).
import Foundation

public protocol UsageFetching: Sendable {
    func fetch() async throws -> UsageSnapshot
}

public protocol UsageTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct CodexUsageClient: UsageFetching {
    private let credentials: @Sendable () throws -> CodexCredentials
    private let transport: any UsageTransport
    private let now: @Sendable () -> Date

    public init(
        credentials: @escaping @Sendable () throws -> CodexCredentials,
        transport: any UsageTransport,
        now: @escaping @Sendable () -> Date = { .now })
    {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    public func fetch() async throws -> UsageSnapshot {
        let credentials = try self.credentials()
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw UsageFailure.invalidResponse
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let status: Int
        do {
            (data, status) = try await self.transport.send(request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw UsageFailure.network
        }
        try Task.checkCancellation()
        // A response from before a local account switch must never be presented as the new account.
        guard try self.credentials() == credentials else { throw UsageFailure.accountChanged }
        switch status {
        case 200...299:
            return try UsageSnapshot.decode(data, now: self.now(), expectedAccountID: credentials.accountID)
        case 401, 403: throw UsageFailure.signInRequired
        case 429: throw UsageFailure.rateLimited
        default: throw UsageFailure.unavailable
        }
    }
}

public final class EphemeralUsageTransport: NSObject, UsageTransport, URLSessionTaskDelegate {
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageFailure.invalidResponse }
        return (data, response.statusCode)
    }

    public func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest) async -> URLRequest?
    {
        // Never forward the user's bearer token through a redirect.
        nil
    }
}
