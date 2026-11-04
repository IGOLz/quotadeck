import Foundation

public enum Provider: String, Codable, Sendable {
    case codex, claude

    public var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    public var shortTitle: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

public struct UsageWindow: Equatable, Codable, Sendable {
    public enum Kind: Equatable, Codable, Sendable {
        case weekly, fiveHour, other(TimeInterval)
    }

    public var kind: Kind
    /// Percent of the window already used (0...100).
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Window length in seconds.
    public var length: TimeInterval

    public init(kind: Kind, usedPercent: Double, resetsAt: Date?, length: TimeInterval) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.length = length
    }

    public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }

    public var label: String {
        switch kind {
        case .weekly: "WEEKLY"
        case .fiveHour: "5 HOURS"
        case .other(let s): s >= 86_400 ? "\(Int(s / 86_400)) DAYS" : "\(Int(s / 3_600)) HOURS"
        }
    }

    public var sortOrder: Int {
        switch kind {
        case .weekly: 0
        case .fiveHour: 1
        case .other: 2
        }
    }

    /// Fraction of the window's time still left: where the bar would be at a steady pace.
    public func paceFraction(now: Date) -> Double? {
        guard let resetsAt, length > 0 else { return nil }
        return min(1, max(0, resetsAt.timeIntervalSince(now) / length))
    }

    public static func kind(forSeconds s: TimeInterval) -> Kind {
        if abs(s - 604_800) < 3_600 { return .weekly }
        if abs(s - 18_000) < 600 { return .fiveHour }
        return .other(s)
    }
}

/// Everything shown for one account. Holds no credentials, so it is safe to hand
/// to the widget extension.
public struct Account: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let provider: Provider
    public var email: String
    /// Subscription shown instead of the email, e.g. "Claude Max 20x", "ChatGPT Pro".
    public var plan: String?
    public var windows: [UsageWindow]
    /// Codex only: rate-limit reset credits available.
    public var resetCredits: Int?
    /// Codex only: subscription active-until date.
    public var expiresAt: Date?
    public var updatedAt: Date?
    public var error: String?

    public init(id: String, provider: Provider, email: String, plan: String? = nil, windows: [UsageWindow] = [],
                resetCredits: Int? = nil, expiresAt: Date? = nil, updatedAt: Date? = nil, error: String? = nil) {
        self.id = id
        self.provider = provider
        self.email = email
        self.plan = plan
        self.windows = windows
        self.resetCredits = resetCredits
        self.expiresAt = expiresAt
        self.updatedAt = updatedAt
        self.error = error
    }
}

public extension Account {
    /// The plan, or the provider name until the plan is known.
    var planLabel: String { plan ?? provider.title }
}

public enum Fmt {
    public static func percent(_ v: Double) -> String {
        if v > 0 && v < 10 { return String(format: "%.1f%%", v) }
        return "\(Int(v.rounded()))%"
    }

    public static func resets(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not started" }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "Resetting…" }
        if s < 60 { return "Resets in less than a minute" }
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        var parts: [String] = []
        if d > 0 {
            parts.append(unit(d, "day"))
            if h > 0 { parts.append(unit(h, "hour")) }
        } else if h > 0 {
            parts.append(unit(h, "hour"))
            if m > 0 { parts.append(unit(m, "minute")) }
        } else {
            parts.append(unit(m, "minute"))
        }
        return "Resets in " + parts.joined(separator: ", ")
    }

    /// Compact form for small widgets: "6d 21h", "2h 13m", "8m".
    public static func resetsShort(_ date: Date?, now: Date) -> String {
        guard let date else { return "not started" }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "now" }
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = max(1, (s % 3_600) / 60)
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    public static func updated(_ date: Date?, now: Date) -> String {
        guard let date else { return "Updating…" }
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "Updated now" }
        if s < 3_600 { return "Updated \(s / 60) min ago" }
        return "Updated \(s / 3_600) h ago"
    }

    public static let expires: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy"
        return f
    }()

    private static func unit(_ n: Int, _ name: String) -> String {
        "\(n) \(name)\(n == 1 ? "" : "s")"
    }
}
