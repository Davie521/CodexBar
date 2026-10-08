import Foundation
import Testing
@testable import CodexBarLiteCore

@Test func `account discovery finds both CLI homes and does not duplicate inherited B`() {
    let home = URL(fileURLWithPath: "/synthetic-home")
    let accounts = CodexAccount.discover(
        home: home,
        environment: ["CODEX_HOME": "/synthetic-home/.codex-b"],
        directoryExists: { $0.lastPathComponent == ".codex-b" })
    #expect(accounts.map(\.label) == ["A", "B"])
    #expect(accounts.map(\.authURL.path) == [
        "/synthetic-home/.codex/auth.json", "/synthetic-home/.codex-b/auth.json",
    ])
}

@Test func `missing B preserves a single account and custom Codex home`() {
    let home = URL(fileURLWithPath: "/synthetic-home")
    let single = CodexAccount.discover(
        home: home,
        environment: [:],
        directoryExists: { _ in false })
    #expect(single.map(\.label) == ["A"])
    let custom = CodexAccount.discover(
        home: home,
        environment: ["CODEX_HOME": "~/custom"],
        directoryExists: { _ in false })
    #expect(custom.map(\.home.path) == ["/synthetic-home/custom"])
    #expect(custom.map(\.label) == ["A"])
}

@Test func `explicit CLI account paths are honored and duplicate homes are collapsed`() {
    let home = URL(fileURLWithPath: "/synthetic-home")
    let accounts = CodexAccount.discover(
        home: home,
        environment: ["CX_ACCOUNT_A_HOME": "~/first", "CX_ACCOUNT_B_HOME": "~/second"],
        directoryExists: { _ in false })
    #expect(accounts.map(\.home.path) == ["/synthetic-home/first", "/synthetic-home/second"])
    let duplicate = CodexAccount.discover(
        home: home,
        environment: ["CX_ACCOUNT_B_HOME": "~/.codex"],
        directoryExists: { _ in true })
    #expect(duplicate.count == 1)
}

@Test(arguments: ["", "  ", "\n"])
func `empty CLI overrides fall back to both default homes`(empty: String) {
    let home = URL(fileURLWithPath: "/synthetic-home")
    let accounts = CodexAccount.discover(
        home: home,
        environment: ["CX_ACCOUNT_A_HOME": empty, "CX_ACCOUNT_B_HOME": empty, "CODEX_HOME": empty],
        directoryExists: { $0.lastPathComponent == ".codex-b" })
    #expect(accounts.map(\.label) == ["A", "B"])
    #expect(accounts.map(\.home.path) == ["/synthetic-home/.codex", "/synthetic-home/.codex-b"])
    let single = CodexAccount.discover(
        home: home,
        environment: ["CX_ACCOUNT_B_HOME": empty],
        directoryExists: { _ in false })
    #expect(single.map(\.label) == ["A"])
}

@Test func `an additional inherited home is preserved beside configured accounts`() {
    let accounts = CodexAccount.discover(
        home: URL(fileURLWithPath: "/synthetic-home"),
        environment: ["CODEX_HOME": "~/custom"],
        directoryExists: { _ in true })
    #expect(accounts.map(\.home.path) == [
        "/synthetic-home/.codex", "/synthetic-home/.codex-b", "/synthetic-home/custom",
    ])
    #expect(accounts.map(\.label) == ["A", "B", "C"])
}

@Test func `aliases for the same home are deduplicated`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".codex-b"), withDestinationURL: home)
    let accounts = CodexAccount.discover(home: root, environment: [:], directoryExists: { _ in true })
    #expect(accounts.count == 1)
    #expect(accounts.first?.label == "A")
}

@Test @MainActor func `both accounts refresh with isolated credentials and independent failures`() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = AccountFixtureTransport()
    var entries: [AccountUsage] = []
    for label in ["A", "B"] {
        let account = CodexAccount(label: label, home: root.appendingPathComponent(label))
        try FileManager.default.createDirectory(at: account.home, withIntermediateDirectories: true)
        let credentials = Data("""
        {"tokens":{"access_token":"fixture-\(label)","account_id":"\(label)"}}
        """.utf8)
        try credentials.write(to: account.authURL)
        entries.append(AccountUsage(account: account, usage: UsageModel(client: CodexUsageClient(
            credentials: { try CodexCredentials.read(from: account.authURL) }, transport: transport))))
    }
    let model = AccountsUsageModel(accounts: entries)
    await model.refresh()
    #expect(model.accounts.map { $0.usage.snapshot?.weeklyWindow?.remainingPercent } == [90, 30])
    #expect(await transport.requestedAccounts.sorted() == ["A", "B"])
    await transport.expireB()
    await model.refresh()
    #expect(model.accounts[0].usage.snapshot?.weeklyWindow?.remainingPercent == 90)
    #expect(model.accounts[0].usage.failure == nil)
    #expect(model.accounts[1].usage.snapshot == nil)
    #expect(model.accounts[1].usage.failure == .signInRequired)
    #expect(!model.isRefreshing)
    await transport.restoreB()
    await model.refresh()
    #expect(model.accounts.map { $0.usage.snapshot?.weeklyWindow?.remainingPercent } == [90, 30])
    #expect(model.accounts[1].usage.failure == nil)
    // The reader must not alter either account's credentials.
    #expect(try CodexCredentials.read(from: entries[0].account.authURL).accountID == "A")
    #expect(try CodexCredentials.read(from: entries[1].account.authURL).accountID == "B")
}

@Test @MainActor func `multi account preview performs no requests`() async {
    let transport = AccountFixtureTransport()
    let entries = ["A", "B"].map { label in
        AccountUsage(
            account: CodexAccount(label: label, home: URL(fileURLWithPath: "/fixture/\(label)")),
            usage: UsageModel(client: CodexUsageClient(
                credentials: { throw UsageFailure.credentialsUnreadable }, transport: transport), example: .example()))
    }
    let model = AccountsUsageModel(accounts: entries)
    await model.refresh()
    #expect(model.isExample)
    #expect(await transport.requestedAccounts.isEmpty)
}

private actor AccountFixtureTransport: UsageTransport {
    var requestedAccounts: [String] = []
    private var bExpired = false

    func expireB() {
        self.bExpired = true
    }

    func restoreB() {
        self.bExpired = false
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let id = request.value(forHTTPHeaderField: "ChatGPT-Account-Id") ?? ""
        guard ["A", "B"].contains(id),
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-\(id)"
        else { throw UsageFailure.accountChanged }
        self.requestedAccounts.append(id)
        if id == "B", self.bExpired { return (Data(), 401) }
        return (Data("""
        {"account_id":"\(id)","plan_type":"pro","rate_limit":{
          "primary_window":{"used_percent":\(id == "A" ? 10 : 70),"limit_window_seconds":604800}
        }}
        """.utf8), 200)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
@MainActor func `concurrent refresh rejects duplicates and drains cancellation`(cancel: Bool) async {
    let clients = [SuspendedUsageClient(), SuspendedUsageClient()]
    let entries = clients.enumerated().map { index, client in
        AccountUsage(
            account: CodexAccount(label: "\(index)", home: URL(fileURLWithPath: "/fixture/\(index)")),
            usage: UsageModel(client: client))
    }
    let model = AccountsUsageModel(accounts: entries)
    let refresh = Task { await model.refresh() }
    // Both fetches must start before either is allowed to complete.
    for client in clients {
        await client.waitForStart()
    }
    #expect(model.isRefreshing)
    await model.refresh()
    for client in clients {
        #expect(await client.calls == 1)
    }
    if cancel { refresh.cancel() }
    for client in clients {
        await client.finish()
    }
    await refresh.value
    #expect(!model.isRefreshing)
    for entry in model.accounts {
        #expect(!entry.usage.isRefreshing)
        #expect((entry.usage.snapshot == nil) == cancel)
        #expect(entry.usage.failure == nil)
    }
}

private actor SuspendedUsageClient: UsageFetching {
    var calls = 0
    private var pending: CheckedContinuation<UsageSnapshot, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    func fetch() async throws -> UsageSnapshot {
        self.calls += 1
        return await withCheckedContinuation { continuation in
            self.pending = continuation
            self.startWaiter?.resume()
            self.startWaiter = nil
        }
    }

    func waitForStart() async {
        guard self.calls == 0 else { return }
        await withCheckedContinuation { self.startWaiter = $0 }
    }

    func finish() {
        self.pending?.resume(returning: .example())
        self.pending = nil
    }
}
