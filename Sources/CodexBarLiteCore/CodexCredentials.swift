// Native auth.json parsing adapted from CodexBar's CodexOAuthCredentials (MIT).
import Foundation

public struct CodexCredentials: Equatable, Sendable {
    let accessToken: String
    let accountID: String?

    public static func parse(_ data: Data) throws -> CodexCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFailure.credentialsUnreadable
        }
        if let apiKey = root["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            throw UsageFailure.subscriptionRequired
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let token = nonEmpty(tokens["access_token"] ?? tokens["accessToken"])
        else { throw UsageFailure.signInRequired }
        let idToken = self.nonEmpty(tokens["id_token"] ?? tokens["idToken"])
        let accountID = self.nonEmpty(tokens["account_id"] ?? tokens["accountId"])
            ?? Self.accountID(in: idToken)
            ?? Self.accountID(in: token)
        return CodexCredentials(accessToken: token, accountID: accountID)
    }

    public static func authURL(home: URL, environment: [String: String]) -> URL {
        let override = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexHome: URL
        if let override, !override.isEmpty {
            let path = override == "~" ? home.path : override.hasPrefix("~/")
                ? home.appendingPathComponent(String(override.dropFirst(2))).path : override
            codexHome = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        }
        return codexHome.appendingPathComponent("auth.json")
    }

    public static func read(from url: URL) throws -> CodexCredentials {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            throw UsageFailure.signInRequired
        } catch {
            throw UsageFailure.credentialsUnreadable
        }
        return try self.parse(data)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func accountID(in token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return self.nonEmpty(auth["chatgpt_account_id"])
    }
}
