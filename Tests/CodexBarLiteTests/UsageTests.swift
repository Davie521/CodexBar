import Foundation
import Testing
@testable import CodexBarLiteCore

private let usageJSON = Data("""
{"account_id":"account-a","plan_type":"pro","rate_limit":{
  "primary_window":{"used_percent":28,"limit_window_seconds":18000,"reset_at":2000000000},
  "secondary_window":{"used_percent":46,"limit_window_seconds":604800,"reset_at":2000500000}
}}
""".utf8)

@Test func `usage maps both windows and remaining percent`() throws {
    let date = Date(timeIntervalSince1970: 1_900_000_000)
    let snapshot = try UsageSnapshot.decode(usageJSON, now: date, expectedAccountID: "account-a")
    #expect(snapshot.plan == "Pro")
    #expect(snapshot.fetchedAt == date)
    #expect(snapshot.windows.map(\.remainingPercent) == [72, 54])
    #expect(snapshot.windows.map(\.title) == ["5 小时", "每周"])
    #expect(snapshot.windows.first?.resetsAt == Date(timeIntervalSince1970: 2_000_000_000))
}

@Test func `weekly primary is not presented as five hour usage`() throws {
    let data = Data("""
    {"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":604800}}}
    """.utf8)
    let snapshot = try UsageSnapshot.decode(data, now: .now, expectedAccountID: nil)
    #expect(snapshot.windows.count == 1)
    #expect(snapshot.windows.first?.title == "每周")
    #expect(snapshot.windows.first?.resetsAt == nil)
}

@Test func `swapped windows are ordered by their actual duration`() throws {
    let data = Data("""
    {"rate_limit":{
      "primary_window":{"used_percent":75,"limit_window_seconds":604800},
      "secondary_window":{"used_percent":20,"limit_window_seconds":18000}
    }}
    """.utf8)
    let snapshot = try UsageSnapshot.decode(data, now: .now, expectedAccountID: nil)
    #expect(snapshot.windows.map(\.usedPercent) == [20, 75])
}

@Test func `malformed optional window preserves the other quota`() throws {
    let data = Data("""
    {"rate_limit":{
      "primary_window":{"used_percent":"bad"},
      "secondary_window":{"used_percent":120,"limit_window_seconds":604800,"reset_at":0}
    }}
    """.utf8)
    let snapshot = try UsageSnapshot.decode(data, now: .now, expectedAccountID: nil)
    #expect(snapshot.windows.count == 1)
    #expect(snapshot.windows.first?.remainingPercent == 0)
    #expect(snapshot.windows.first?.resetsAt == nil)
}

@Test func `missing quotas never become a fabricated full allowance`() {
    #expect(throws: UsageFailure.noQuota) {
        try UsageSnapshot.decode(Data("{}".utf8), now: .now, expectedAccountID: nil)
    }
    #expect(throws: UsageFailure.invalidResponse) {
        try UsageSnapshot.decode(Data("not json".utf8), now: .now, expectedAccountID: nil)
    }
}

@Test func `response from a different account is rejected`() {
    #expect(throws: UsageFailure.accountChanged) {
        try UsageSnapshot.decode(usageJSON, now: .now, expectedAccountID: "account-b")
    }
}

@Test func `invalid negative percentages never become a full allowance`() {
    let data = Data("""
    {"rate_limit":{"primary_window":{"used_percent":-1,"limit_window_seconds":18000}}}
    """.utf8)
    #expect(throws: UsageFailure.noQuota) {
        try UsageSnapshot.decode(data, now: .now, expectedAccountID: nil)
    }
}

@Test func `authenticated transport refuses redirects without sending a request`() async throws {
    let originalURL = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))
    let redirectURL = try #require(URL(string: "https://example.invalid/redirect"))
    let response = try #require(HTTPURLResponse(url: originalURL, statusCode: 302, httpVersion: nil, headerFields: nil))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: originalURL) // Never resumed: no network or credential access.
    let transport = EphemeralUsageTransport()
    let result = await transport.urlSession(
        session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: redirectURL))
    #expect(result == nil)
}

@Test func `exhausted weekly quota takes priority in the menu bar`() throws {
    let data = Data("""
    {"rate_limit":{
      "primary_window":{"used_percent":10,"limit_window_seconds":18000},
      "secondary_window":{"used_percent":100,"limit_window_seconds":604800}
    }}
    """.utf8)
    let snapshot = try UsageSnapshot.decode(data, now: .now, expectedAccountID: nil)
    #expect(snapshot.menuWindow?.remainingPercent == 0)
    #expect(snapshot.menuWindow?.title == "每周")
}

@Test func `crossing a reset requires confirmation instead of resetting the number`() {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let window = UsageWindow(id: "primary", usedPercent: 90, duration: 18000, resetsAt: now)
    #expect(window.isAwaitingReset(at: now))
    #expect(window.remainingPercent == 10)
}

@Test func `credentials accept native snake and camel case fields`() throws {
    for fields in [
        "\"access_token\":\"fixture-token\",\"account_id\":\"account-a\"",
        "\"accessToken\":\"fixture-token\",\"accountId\":\"account-a\"",
    ] {
        let credentials = try CodexCredentials.parse(Data("{\"tokens\":{\(fields)}}".utf8))
        #expect(credentials.accessToken == "fixture-token")
        #expect(credentials.accountID == "account-a")
    }
}

@Test func `credentials recover the account from native token claims`() throws {
    let claims = Data("""
    {"https://api.openai.com/auth":{"chatgpt_account_id":"claim-account"}}
    """.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
    let data = Data("{\"tokens\":{\"access_token\":\"header.\(claims).signature\"}}".utf8)
    #expect(try CodexCredentials.parse(data).accountID == "claim-account")
}

@Test func `missing and API key credentials produce useful errors`() {
    #expect(throws: UsageFailure.signInRequired) {
        try CodexCredentials.parse(Data("{\"tokens\":{\"access_token\":\"  \"}}".utf8))
    }
    #expect(throws: UsageFailure.subscriptionRequired) {
        try CodexCredentials.parse(Data("{\"OPENAI_API_KEY\":\"fixture-key\"}".utf8))
    }
    #expect(throws: UsageFailure.credentialsUnreadable) {
        try CodexCredentials.parse(Data("bad".utf8))
    }
}

@Test func `config path respects a custom Codex home without reading files`() {
    let home = URL(fileURLWithPath: "/synthetic-home")
    #expect(CodexCredentials.authURL(home: home, environment: [:]).path == "/synthetic-home/.codex/auth.json")
    #expect(CodexCredentials.authURL(home: home, environment: ["CODEX_HOME": "~/work-codex"]).path
        == "/synthetic-home/work-codex/auth.json")
    #expect(CodexCredentials.authURL(home: home, environment: ["CODEX_HOME": "/fixture/codex"]).path
        == "/fixture/codex/auth.json")
}

@Test func `client sends only the Codex request with scoped account headers`() async throws {
    let transport = StubTransport(data: usageJSON)
    let client = CodexUsageClient(credentials: { SelfFixture.credentials }, transport: transport)
    let snapshot = try await client.fetch()
    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-a")
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(snapshot.windows.count == 2)
}

@Test(arguments: [401, 403, 429, 500])
func `client handles service errors without exposing response bodies`(status: Int) async {
    let transport = StubTransport(data: Data("sensitive response body".utf8), status: status)
    let client = CodexUsageClient(credentials: { SelfFixture.credentials }, transport: transport)
    let expected: UsageFailure = status == 429 ? .rateLimited : status >= 500 ? .unavailable : .signInRequired
    await #expect(throws: expected) { try await client.fetch() }
    #expect(!expected.message.contains("sensitive"))
}

@Test func `account switch during the request discards the old response`() async {
    let store = FixtureCredentialStore()
    let transport = StubTransport(data: usageJSON, onSend: { store.switchAccount() })
    let client = CodexUsageClient(credentials: { store.read() }, transport: transport)
    await #expect(throws: UsageFailure.accountChanged) { try await client.fetch() }
}

@Test @MainActor func `failed refresh clears the previous account quota`() async {
    let client = SequenceClient(results: [.success(.example()), .failure(.signInRequired), .success(.example())])
    let model = UsageModel(client: client)
    await model.refresh()
    #expect(model.snapshot != nil)
    await model.refresh()
    #expect(model.snapshot == nil)
    #expect(model.failure == .signInRequired)
    #expect(!model.isRefreshing)
    await model.refresh()
    #expect(model.snapshot != nil)
    #expect(model.failure == nil)
}

@Test @MainActor func `preview never calls the live fetching boundary`() async {
    let client = SequenceClient(results: [])
    let model = UsageModel(client: client, example: .example())
    await model.refresh()
    #expect(model.isExample)
    #expect(await client.calls == 0)
}

private enum SelfFixture {
    static let credentials = CodexCredentials(accessToken: "fixture-token", accountID: "account-a")
}

private actor StubTransport: UsageTransport {
    let data: Data
    let status: Int
    let onSend: @Sendable () -> Void
    var requests: [URLRequest] = []

    init(data: Data, status: Int = 200, onSend: @escaping @Sendable () -> Void = {}) {
        self.data = data
        self.status = status
        self.onSend = onSend
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        self.requests.append(request)
        self.onSend()
        return (self.data, self.status)
    }
}

private actor SequenceClient: UsageFetching {
    var results: [Result<UsageSnapshot, UsageFailure>]
    var calls = 0

    init(results: [Result<UsageSnapshot, UsageFailure>]) {
        self.results = results
    }

    func fetch() async throws -> UsageSnapshot {
        self.calls += 1
        return try self.results.removeFirst().get()
    }
}

/// All mutable state is private and every access holds the same lock.
private final class FixtureCredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = SelfFixture.credentials

    func read() -> CodexCredentials {
        self.lock.withLock { self.value }
    }

    func switchAccount() {
        self.lock.withLock { self.value = CodexCredentials(accessToken: "other-fixture", accountID: "account-b") }
    }
}
