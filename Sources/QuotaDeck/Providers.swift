import CryptoKit
import Foundation
import QuotaDeckKit

/// An account found on this Mac, with the credentials needed to query its usage.
/// Tokens are re-read on every refresh, so they are always the ones Claude Code,
/// the Codex CLI or CLIProxyAPI most recently refreshed.
struct AccountRef: Sendable {
    let id: String
    let provider: Provider
    let email: String
    let token: String
    var accountId: String? = nil
    var idToken: String? = nil
    /// When the access token expires, if known. When the same account is found in
    /// more than one place, the token that lasts longer wins.
    var expiresAt: Date? = nil
    /// Where it was found, for `--list-accounts`.
    var source = ""
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
        case .http(401), .http(403): "Token expired — it refreshes the next time you use the CLI"
        case .http(429): "Rate limited — retrying later"
        case .http(let c): "HTTP \(c)"
        case .badResponse: "Unexpected response"
        }
    }
}

// MARK: - Discovery

enum Discovery {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let env = ProcessInfo.processInfo.environment

    static func accounts() -> [AccountRef] {
        var refs: [AccountRef] = []
        var index: [String: Int] = [:]
        // The same account can show up in several places (say Claude Code and CLIProxyAPI):
        // keep its first position, but the token that expires last.
        func add(_ r: AccountRef) {
            guard let i = index[r.id] else { index[r.id] = refs.count; refs.append(r); return }
            if (r.expiresAt ?? .distantPast) > (refs[i].expiresAt ?? .distantPast) { refs[i] = r }
        }

        // The CLIs' own sign-ins first: they keep their tokens fresh.
        codexHomes().forEach { codexHome($0).map(add) }
        claudeConfigDirs().forEach { claudeCode($0).map(add) }

        // CLIProxyAPI auth files (Claude accounts, plus any Codex ones).
        var claude: [(prio: Int, ref: AccountRef)] = []
        for dir in cliProxyAuthDirs() {
            for (obj, name) in jsonFiles(in: dir) {
                if obj["disabled"] as? Bool == true { continue }
                guard let token = obj["access_token"] as? String, !token.isEmpty else { continue }
                let email = obj["email"] as? String ?? name
                let expires = UsageAPI.iso(obj["expired"] as? String)
                switch obj["type"] as? String {
                case "claude":
                    let uuid = obj["account_uuid"] as? String ?? email
                    let prio = (obj["priority"] as? NSNumber)?.intValue ?? 0
                    claude.append((prio, AccountRef(id: "claude:\(uuid)", provider: .claude, email: email,
                                                    token: token, expiresAt: expires,
                                                    source: dir.appendingPathComponent(name).path)))
                case "codex":
                    let acct = obj["account_id"] as? String
                    add(AccountRef(id: "codex:\(acct ?? email)", provider: .codex, email: email, token: token,
                                   accountId: acct, idToken: obj["id_token"] as? String,
                                   expiresAt: expires ?? JWT.expiry(token),
                                   source: dir.appendingPathComponent(name).path))
                default: break
                }
            }
        }
        claude.sorted { $0.prio != $1.prio ? $0.prio > $1.prio : $0.ref.email < $1.ref.email }
            .forEach { add($0.ref) }
        return refs
    }

    // MARK: Codex CLI

    private static func codexHomes() -> [URL] {
        var homes: [URL] = []
        if let dir = env["CODEX_HOME"], !dir.isEmpty { homes.append(URL(fileURLWithPath: expand(dir))) }
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
                          accountId: acct, idToken: idToken, expiresAt: JWT.expiry(token),
                          source: dir.appendingPathComponent("auth.json").path)
    }

    // MARK: Claude Code

    /// A Claude Code configuration directory: `~/.claude` by default, or one selected
    /// with `CLAUDE_CONFIG_DIR` (found from the environment or as `~/.claude-*`).
    struct ClaudeConfig {
        let dir: URL
        let isDefault: Bool
    }

    static func claudeConfigDirs() -> [ClaudeConfig] {
        var configs = [ClaudeConfig(dir: home.appendingPathComponent(".claude"), isDefault: true)]
        var custom: [URL] = []
        if let dir = env["CLAUDE_CONFIG_DIR"], !dir.isEmpty { custom.append(URL(fileURLWithPath: expand(dir))) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        for n in names.sorted() where n.hasPrefix(".claude-") || n.hasPrefix(".claude_") {
            let dir = home.appendingPathComponent(n)
            // Only real config directories: they hold their own .claude.json.
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".claude.json").path) {
                custom.append(dir)
            }
        }
        var seen = Set([configs[0].dir.standardizedFileURL.path])
        for dir in custom where seen.insert(dir.standardizedFileURL.path).inserted {
            configs.append(ClaudeConfig(dir: dir.standardizedFileURL, isDefault: false))
        }
        return configs
    }

    /// The account Claude Code is signed in to. Claude Code keeps its OAuth token in the
    /// login keychain ("Claude Code-credentials", plus a hash of the directory when
    /// CLAUDE_CONFIG_DIR is set) or, failing that, in `<config dir>/.credentials.json`.
    private static func claudeCode(_ config: ClaudeConfig) -> AccountRef? {
        var service = "Claude Code-credentials"
        if !config.isDefault {
            let digest = SHA256.hash(data: Data(config.dir.path.precomposedStringWithCanonicalMapping.utf8))
            service += "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        }
        let file = config.dir.appendingPathComponent(".credentials.json")
        let keychain = Keychain.genericPassword(service: service)
        guard let data = keychain ?? (try? Data(contentsOf: file)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }

        // Who it is: the global config next to it (~/.claude.json for the default directory).
        let configFile = config.isDefault
            ? home.appendingPathComponent(".claude.json")
            : config.dir.appendingPathComponent(".claude.json")
        let account = (try? Data(contentsOf: configFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["oauthAccount"] as? [String: Any]
        let email = account?["emailAddress"] as? String ?? "Claude Code"
        let uuid = account?["accountUuid"] as? String ?? (account == nil ? service : email)
        return AccountRef(id: "claude:\(uuid)", provider: .claude, email: email, token: token, expiresAt: expires,
                          source: keychain != nil ? "keychain item \"\(service)\"" : file.path)
    }

    // MARK: CLIProxyAPI

    /// Every CLIProxyAPI auth directory that may exist: the `auth-dir` of each config file
    /// found in the usual places, plus the default locations.
    static func cliProxyAuthDirs() -> [URL] {
        let configs = [
            home.appendingPathComponent(".config/cliproxyapi/config.yaml"),
            home.appendingPathComponent(".cli-proxy-api/config.yaml"),
            URL(fileURLWithPath: "/opt/homebrew/etc/cliproxyapi.conf"),  // Homebrew, Apple silicon
            URL(fileURLWithPath: "/usr/local/etc/cliproxyapi.conf"),     // Homebrew, Intel
        ]
        let dirs = configs.compactMap(authDir(inConfig:)) + [
            home.appendingPathComponent(".cli-proxy-api"),
            home.appendingPathComponent(".config/cliproxyapi/auth"),
        ]
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// `auth-dir: "~/.cli-proxy-api"  # comment` → the expanded path.
    private static func authDir(inConfig url: URL) -> URL? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: {
                  $0.trimmingCharacters(in: .whitespaces).hasPrefix("auth-dir:")
              }) else { return nil }
        var v = String(line.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces)
        if let q = v.first, q == "\"" || q == "'" {
            v = String(v.dropFirst().prefix { $0 != q })
        } else if let hash = v.range(of: " #") {
            v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return v.isEmpty ? nil : URL(fileURLWithPath: expand(v))
    }

    // MARK: Helpers

    private static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? home.path + path.dropFirst() : path
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

/// Reads generic passwords through `/usr/bin/security`. Claude Code stores its keychain item
/// with that tool, so the item's access list already trusts it and macOS shows no prompt
/// (reading it directly with Security.framework would ask the user on every rebuild).
enum Keychain {
    /// Items that could not be read (access denied, keychain locked…) are not retried for a
    /// while, so a denied prompt does not come back on every refresh. Refreshes are serial.
    nonisolated(unsafe) private static var failedAt: [String: Date] = [:]

    static func genericPassword(service: String) -> Data? {
        if let t = failedAt[service], t > Date().addingTimeInterval(-1_800) { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        switch p.terminationStatus {
        case 0:
            failedAt[service] = nil
            var d = data
            while d.last == 0x0A { d.removeLast() }
            return d.isEmpty ? nil : d
        case 44:  // errSecItemNotFound: nothing stored under this name.
            return nil
        default:
            failedAt[service] = Date()
            return nil
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

    /// The `exp` claim, when the token is a JWT (Codex tokens are; Claude tokens are not).
    static func expiry(_ token: String) -> Date? {
        (payload(token)?["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
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
