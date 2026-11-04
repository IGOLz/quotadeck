import QuotaDeckKit
import Foundation

/// An account found on disk, with the credentials needed to query its usage.
/// Tokens are re-read from disk on every refresh, so they are always the ones
/// CLIProxyAPI / the Codex CLI most recently refreshed.
struct AccountRef: Sendable {
    let id: String
    let provider: Provider
    let email: String
    let token: String
    var accountId: String? = nil
    var idToken: String? = nil
}

struct Fetched: Sendable {
    var windows: [UsageWindow]
    var email: String? = nil
    var resetCredits: Int? = nil
    var expiresAt: Date? = nil
    var plan: String? = nil
}

enum FetchError: LocalizedError {
    case http(Int)
    case badResponse

    var isRateLimit: Bool { if case .http(429) = self { true } else { false } }

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): "Token expired — waiting for refresh"
        case .http(429): "Rate limited — retrying later"
        case .http(let c): "HTTP \(c)"
        case .badResponse: "Unexpected response"
        }
    }
}

// MARK: - Discovery

enum Discovery {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func accounts() -> [AccountRef] {
        var refs: [AccountRef] = []
        var seen = Set<String>()
        func add(_ r: AccountRef) { if seen.insert(r.id).inserted { refs.append(r) } }

        // Codex CLI homes first: the CLI keeps their tokens fresh.
        codexHomes().forEach { codexHome($0).map(add) }

        // CLIProxyAPI auth files (Claude accounts, plus any Codex ones).
        var claude: [(prio: Int, ref: AccountRef)] = []
        for (obj, name) in jsonFiles(in: cliProxyAuthDir()) {
            if obj["disabled"] as? Bool == true { continue }
            guard let token = obj["access_token"] as? String, !token.isEmpty else { continue }
            let email = obj["email"] as? String ?? name
            switch obj["type"] as? String {
            case "claude":
                let uuid = obj["account_uuid"] as? String ?? email
                let prio = (obj["priority"] as? NSNumber)?.intValue ?? 0
                claude.append((prio, AccountRef(id: "claude:\(uuid)", provider: .claude, email: email, token: token)))
            case "codex":
                let acct = obj["account_id"] as? String
                add(AccountRef(id: "codex:\(acct ?? email)", provider: .codex, email: email, token: token,
                               accountId: acct, idToken: obj["id_token"] as? String))
            default: break
            }
        }
        claude.sorted { $0.prio != $1.prio ? $0.prio > $1.prio : $0.ref.email < $1.ref.email }
            .forEach { add($0.ref) }
        return refs
    }

    static func cliProxyAuthDir() -> URL {
        let config = home.appendingPathComponent(".config/cliproxyapi/config.yaml")
        if let text = try? String(contentsOf: config, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: {
               $0.trimmingCharacters(in: .whitespaces).hasPrefix("auth-dir:")
           }) {
            var v = String(line.split(separator: ":", maxSplits: 1)[1])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if v.hasPrefix("~") { v = home.path + v.dropFirst() }
            if !v.isEmpty { return URL(fileURLWithPath: v) }
        }
        return home.appendingPathComponent(".config/cliproxyapi/auth")
    }

    private static func codexHomes() -> [URL] {
        var homes: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            homes.append(URL(fileURLWithPath: env))
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        for n in names.sorted() where n == ".codex" || n.hasPrefix(".codex-") || n.hasPrefix(".codex_") {
            homes.append(home.appendingPathComponent(n))
        }
        return homes
    }

    private static func codexHome(_ dir: URL) -> AccountRef? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("auth.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        let acct = tokens["account_id"] as? String
        let idToken = tokens["id_token"] as? String
        let email = idToken.flatMap { JWT.payload($0)?["email"] as? String } ?? dir.lastPathComponent
        return AccountRef(id: "codex:\(acct ?? email)", provider: .codex, email: email, token: token,
                          accountId: acct, idToken: idToken)
    }

    private static func jsonFiles(in dir: URL) -> [([String: Any], String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (obj, name)
        }
    }
}

enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - Plans

enum Plan {
    /// "Claude Max 20x", "Claude Pro", … Prefers the name Anthropic itself shows, when the profile has one.
    static func claude(profile: [String: Any]) -> String? {
        let org = profile["organization"] as? [String: Any] ?? [:]
        let account = profile["account"] as? [String: Any] ?? [:]
        if let name = org["plan_display_name"] as? String, !name.isEmpty {
            return name.lowercased().hasPrefix("claude") ? name : "Claude \(name)"
        }
        let tier = (org["rate_limit_tier"] as? String ?? "").lowercased()
        switch org["organization_type"] as? String {
        case "claude_max":
            if tier.contains("20x") { return "Claude Max 20x" }
            if tier.contains("5x") { return "Claude Max 5x" }
            return "Claude Max"
        case "claude_pro": return "Claude Pro"
        case "claude_team": return "Claude Team"
        case "claude_enterprise": return "Claude Enterprise"
        default:
            if account["has_claude_max"] as? Bool == true { return "Claude Max" }
            if account["has_claude_pro"] as? Bool == true { return "Claude Pro" }
            return org.isEmpty ? nil : "Claude Free"
        }
    }

    /// Codex quota comes with a ChatGPT plan: "ChatGPT Plus", "ChatGPT Pro", …
    static func chatGPT(_ type: String) -> String {
        switch type.lowercased() {
        case "plus": "ChatGPT Plus"
        case "pro": "ChatGPT Pro"
        case "team": "ChatGPT Team"
        case "business": "ChatGPT Business"
        case "enterprise": "ChatGPT Enterprise"
        case "edu": "ChatGPT Edu"
        case "free": "ChatGPT Free"
        default: "ChatGPT " + type.capitalized
        }
    }
}

// MARK: - Network

enum UsageAPI {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()

    static func fetch(_ ref: AccountRef) async throws -> Fetched {
        switch ref.provider {
        case .claude: try await claude(ref)
        case .codex: try await codex(ref)
        }
    }

    private static func get(_ url: String, headers: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badResponse
        }
        return obj
    }

    // Claude: same endpoint Claude Code's /usage uses.
    private static func claude(_ ref: AccountRef) async throws -> Fetched {
        let obj = try await get("https://api.anthropic.com/api/oauth/usage", headers: [
            "Authorization": "Bearer \(ref.token)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1",
            "Accept": "application/json",
        ])
        func window(_ key: String, _ kind: UsageWindow.Kind, _ length: TimeInterval) -> UsageWindow {
            let d = obj[key] as? [String: Any]
            return UsageWindow(kind: kind,
                               usedPercent: (d?["utilization"] as? NSNumber)?.doubleValue ?? 0,
                               resetsAt: iso(d?["resets_at"] as? String),
                               length: length)
        }
        return Fetched(windows: [window("seven_day", .weekly, 604_800), window("five_hour", .fiveHour, 18_000)])
    }

    // Codex: same endpoint the Codex CLI's /status uses.
    private static func codex(_ ref: AccountRef) async throws -> Fetched {
        var headers = ["Authorization": "Bearer \(ref.token)", "User-Agent": "codex-cli", "Accept": "application/json"]
        if let a = ref.accountId { headers["ChatGPT-Account-Id"] = a }
        let obj = try await get("https://chatgpt.com/backend-api/wham/usage", headers: headers)

        let rl = obj["rate_limit"] as? [String: Any] ?? [:]
        let windows: [UsageWindow] = ["primary_window", "secondary_window"].compactMap { key in
            guard let w = rl[key] as? [String: Any] else { return nil }
            let length = (w["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 0
            var reset: Date?
            if let at = (w["reset_at"] as? NSNumber)?.doubleValue {
                reset = Date(timeIntervalSince1970: at)
            } else if let after = (w["reset_after_seconds"] as? NSNumber)?.doubleValue {
                reset = Date().addingTimeInterval(after)
            }
            return UsageWindow(kind: UsageWindow.kind(forSeconds: length),
                               usedPercent: (w["used_percent"] as? NSNumber)?.doubleValue ?? 0,
                               resetsAt: reset, length: length)
        }.sorted { $0.sortOrder < $1.sortOrder }

        let credits = (obj["rate_limit_reset_credits"] as? [String: Any])?["available_count"] as? NSNumber
        let auth = ref.idToken.flatMap { JWT.payload($0)?["https://api.openai.com/auth"] as? [String: Any] }
        let planType = obj["plan_type"] as? String ?? auth?["chatgpt_plan_type"] as? String
        return Fetched(windows: windows,
                       email: obj["email"] as? String,
                       resetCredits: credits?.intValue,
                       expiresAt: iso(auth?["chatgpt_subscription_active_until"] as? String),
                       plan: planType.map(Plan.chatGPT))
    }

    /// Claude's subscription, from the OAuth profile (the usage endpoint does not include it).
    /// Returns nil on any failure; the caller retries later.
    static func claudePlan(_ ref: AccountRef) async -> String? {
        guard let obj = try? await get("https://api.anthropic.com/api/oauth/profile", headers: [
            "Authorization": "Bearer \(ref.token)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1",
            "Accept": "application/json",
        ]) else { return nil }
        return Plan.claude(profile: obj)
    }

    private static let isoFormatter = ISO8601DateFormatter()

    /// Parses ISO-8601 dates, tolerating microsecond fractions ("…00.091577+00:00").
    static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return isoFormatter.date(from: trimmed)
    }
}
