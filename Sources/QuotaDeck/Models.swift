import Foundation

enum Provider: String {
    case codex, claude

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }
}

struct UsageWindow: Equatable {
    enum Kind: Equatable {
        case weekly, fiveHour, other(TimeInterval)
    }

    var kind: Kind
    /// Percent of the window already used (0...100).
    var usedPercent: Double
    var resetsAt: Date?
    /// Window length in seconds.
    var length: TimeInterval

    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }

    var label: String {
        switch kind {
        case .weekly: "WEEKLY"
        case .fiveHour: "5 HOURS"
        case .other(let s): s >= 86_400 ? "\(Int(s / 86_400)) DAYS" : "\(Int(s / 3_600)) HOURS"
        }
    }

    var sortOrder: Int {
        switch kind {
        case .weekly: 0
        case .fiveHour: 1
        case .other: 2
        }
    }

    /// Fraction of the window's time still left: where the bar would be at a steady pace.
    func paceFraction(now: Date) -> Double? {
        guard let resetsAt, length > 0 else { return nil }
        return min(1, max(0, resetsAt.timeIntervalSince(now) / length))
    }

    static func kind(forSeconds s: TimeInterval) -> Kind {
        if abs(s - 604_800) < 3_600 { return .weekly }
        if abs(s - 18_000) < 600 { return .fiveHour }
        return .other(s)
    }
}

struct Account: Identifiable, Equatable {
    let id: String
    let provider: Provider
    var email: String
    var windows: [UsageWindow] = []
    /// Codex only: rate-limit reset credits available.
    var resetCredits: Int?
    /// Codex only: subscription active-until date.
    var expiresAt: Date?
    var updatedAt: Date?
    var error: String?
}

enum Fmt {
    static func percent(_ v: Double) -> String {
        if v > 0 && v < 10 { return String(format: "%.1f%%", v) }
        return "\(Int(v.rounded()))%"
    }

    static func resets(_ date: Date?, now: Date) -> String {
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

    static func updated(_ date: Date?, now: Date) -> String {
        guard let date else { return "Updating…" }
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "Updated now" }
        if s < 3_600 { return "Updated \(s / 60) min ago" }
        return "Updated \(s / 3_600) h ago"
    }

    static let expires: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy"
        return f
    }()

    private static func unit(_ n: Int, _ name: String) -> String {
        "\(n) \(name)\(n == 1 ? "" : "s")"
    }
}
