import Foundation
import Observation

public struct CodexAccount: Identifiable, Equatable, Sendable {
    public let label: String
    public let home: URL

    public var id: String {
        self.home.path
    }

    public var authURL: URL {
        self.home.appendingPathComponent("auth.json")
    }

    public init(label: String, home: URL) {
        self.label = label
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Matches the cxa/cxb configuration without executing shell code or scanning unrelated directories.
    public static func discover(
        home: URL,
        environment: [String: String],
        directoryExists: (URL) -> Bool) -> [CodexAccount]
    {
        func account(_ label: String, path: String) -> CodexAccount {
            let authURL = CodexCredentials.authURL(home: home, environment: ["CODEX_HOME": path])
            return CodexAccount(label: label, home: authURL.deletingLastPathComponent())
        }
        func configuredPath(_ key: String) -> String? {
            guard let path = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                return nil
            }
            return path
        }
        let firstPath = configuredPath("CX_ACCOUNT_A_HOME")
        let secondPath = configuredPath("CX_ACCOUNT_B_HOME")
        let first = account("A", path: firstPath ?? home.appendingPathComponent(".codex").path)
        let second = account("B", path: secondPath ?? home.appendingPathComponent(".codex-b").path)
        var accounts = [first]
        if directoryExists(second.home) || secondPath != nil {
            accounts.append(second)
        }
        if let override = configuredPath("CODEX_HOME") {
            let inherited = account(accounts.count == 1 ? "A" : "C", path: override)
            if !accounts.contains(where: { $0.id == inherited.id }) {
                // Preserve a custom CODEX_HOME as the single account when no A/B setup exists.
                if accounts.count == 1 { accounts = [] }
                accounts.append(inherited)
            }
        }
        var seen: Set<String> = []
        return accounts.filter { seen.insert($0.id).inserted }
    }
}

public struct AccountUsage: Identifiable, Sendable {
    public let account: CodexAccount
    public let usage: UsageModel
    public var id: String {
        self.account.id
    }

    public init(account: CodexAccount, usage: UsageModel) {
        self.account = account
        self.usage = usage
    }
}

@MainActor
@Observable
public final class AccountsUsageModel {
    public let accounts: [AccountUsage]
    public var showRemaining = true
    public private(set) var isRefreshing = false
    public var isExample: Bool {
        self.accounts.allSatisfy(\.usage.isExample)
    }

    public init(accounts: [AccountUsage]) {
        self.accounts = accounts
    }

    public func refresh() async {
        guard !self.isRefreshing, !self.isExample else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for account in self.accounts {
                group.addTask { await account.usage.refresh() }
            }
        }
    }
}
