import SwiftUI
import WidgetKit

// MARK: - Timeline entry

public struct QuotaEntry: TimelineEntry {
    /// `missing`: the account a configured widget points at is no longer on this Mac.
        public enum State: Sendable { case ok, noData, missing }

    public let date: Date
    public let accounts: [Account]
    public let state: State

    public init(date: Date, accounts: [Account], state: State = .ok) {
        self.date = date
        self.accounts = accounts
        self.state = state
    }

    /// Plausible data for the widget gallery and placeholders.
    public static func sample(date: Date = Date()) -> QuotaEntry {
        func w(_ kind: UsageWindow.Kind, used: Double, in s: TimeInterval, length: TimeInterval) -> UsageWindow {
            UsageWindow(kind: kind, usedPercent: used, resetsAt: date.addingTimeInterval(s), length: length)
        }
        let accounts = [
            Account(id: "sample-codex", provider: .codex, email: "you@example.com", plan: "ChatGPT Pro",
                    windows: [w(.weekly, used: 38, in: 3 * 86_400, length: 604_800)],
                    resetCredits: 2, expiresAt: date.addingTimeInterval(20 * 86_400), updatedAt: date),
            Account(id: "sample-claude", provider: .claude, email: "you@example.com", plan: "Claude Max 20x",
                    windows: [w(.weekly, used: 22, in: 5 * 86_400, length: 604_800),
                              w(.fiveHour, used: 40, in: 2 * 3_600, length: 18_000)],
                    updatedAt: date),
        ]
        return QuotaEntry(date: date, accounts: accounts)
    }
}

// MARK: - Root view

/// The WidgetKit widget's content for every supported family.
public struct QuotaWidgetView: View {
    let entry: QuotaEntry
    private let familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily

    /// `family` is only for rendering outside WidgetKit (snapshots); widgets read it from the environment.
    public init(entry: QuotaEntry, family: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = family
    }

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.background, for: .widget)
    }

    @ViewBuilder private var content: some View {
        let now = entry.date
        let accounts = entry.accounts
        if entry.state != .ok || accounts.isEmpty {
            EmptyWidget(state: entry.state)
        } else {
            switch family {
            case .systemSmall:
                if accounts.count == 1 {
                    SingleAccountSmall(account: accounts[0], now: now)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(accounts.prefix(3)) { CompactRow(account: $0, all: accounts, now: now) }
                        Spacer(minLength: 0)
                        if accounts.count > 3 { MoreLabel(count: accounts.count - 3) }
                    }
                }
            case .systemMedium:
                Columns(accounts: accounts, max: 3, now: now, detailed: false)
            case .systemExtraLarge:
                Columns(accounts: accounts, max: 4, now: now, detailed: true)
            default:
                ViewThatFits(in: .vertical) {
                    StripList(accounts: accounts, now: now)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(accounts.prefix(6)) { CompactRow(account: $0, all: accounts, now: now) }
                        Spacer(minLength: 0)
                        if accounts.count > 6 { MoreLabel(count: accounts.count - 6) }
                    }
                }
            }
        }
    }
}

// MARK: - Helpers

private extension Account {
    var primary: UsageWindow? { windows.first }
    var secondary: UsageWindow? { windows.count > 1 ? windows[1] : nil }
    var accent: Color { Theme.accent(provider) }

    /// Data older than this means the app has not refreshed for a while.
    func isStale(now: Date) -> Bool {
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) > 15 * 60
    }

    /// Short label next to the logo; the plan ("Ultra", "Pro") tells same-provider accounts apart.
    func shortName(among all: [Account]) -> String {
        guard all.filter({ $0.provider == provider }).count > 1, let plan else { return provider.shortTitle }
        for prefix in ["Claude ", "ChatGPT "] where plan.hasPrefix(prefix) {
            return String(plan.dropFirst(prefix.count))  // the logo already names the provider
        }
        return plan
    }
}

private func shortReset(_ w: UsageWindow, _ now: Date) -> String {
    w.resetsAt == nil ? "Not started" : "Resets \(Fmt.resetsShort(w.resetsAt, now: now))"
}

private func pace(_ w: UsageWindow, _ now: Date) -> Double? {
    w.kind == .weekly ? w.paceFraction(now: now) : nil
}

private struct StatusDot: View {
    let account: Account
    let now: Date

    var body: some View {
        if account.error != nil || account.isStale(now: now) {
            Circle().fill(Color.orange).frame(width: 5, height: 5)
        }
    }
}

private struct MoreLabel: View {
    let count: Int
    var body: some View {
        Text("+\(count) more").font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

private struct Percent: View {
    let value: Double
    let size: CGFloat
    let color: Color
    var weight: Font.Weight = .regular

    var body: some View {
        Text(Fmt.percent(value))
            .font(.system(size: size, weight: weight))
            .monospacedDigit()
            .foregroundStyle(color)
            .widgetAccentable()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

private struct WindowLabel: View {
    let text: String
    var size: CGFloat = 9.5
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - Empty

private struct EmptyWidget: View {
    let state: QuotaEntry.State

    private var message: String {
        switch state {
        case .noData: "Open QuotaDeck to load your accounts"
        case .missing: "Account not found. Edit the widget to choose another."
        case .ok: "No Claude or Codex accounts found"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Small

/// One account per row: name, weekly %, bar, and the second window below.
private struct CompactRow: View {
    let account: Account
    let all: [Account]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                ProviderLogo(provider: account.provider).frame(width: 13, height: 13)
                Text(account.shortName(among: all))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                StatusDot(account: account, now: now)
                Spacer(minLength: 4)
                if let w = account.primary {
                    Percent(value: w.remainingPercent, size: 15, color: account.accent, weight: .medium)
                }
            }
            if let w = account.primary {
                UsageBar(fraction: w.remainingPercent / 100, pace: pace(w, now),
                         color: account.accent, thickness: 4)
                Text(detail(w))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(account.error ?? "Loading…")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func detail(_ w: UsageWindow) -> String {
        let reset = shortReset(w, now)
        guard let s = account.secondary else { return reset }
        let label = s.kind == .fiveHour ? "5H" : s.label
        return "\(reset) · \(label) \(Fmt.percent(s.remainingPercent))"
    }
}

/// One account filling a small widget: the per-account widget, or a single account.
private struct SingleAccountSmall: View {
    let account: Account
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ProviderLogo(provider: account.provider).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.provider.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(account.accent)
                        .lineLimit(1)
                    if let plan = account.plan {
                        Text(plan)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                StatusDot(account: account, now: now)
            }
            Spacer(minLength: 2)
            if let w = account.primary {
                HStack(alignment: .lastTextBaseline) {
                    WindowLabel(text: w.label)
                    Spacer(minLength: 2)
                    Percent(value: w.remainingPercent, size: 30, color: account.accent)
                }
                UsageBar(fraction: w.remainingPercent / 100, pace: pace(w, now),
                         color: account.accent, thickness: 5)
                    .padding(.vertical, 2)
                Text(shortReset(w, now))
                    .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                if let s = account.secondary {
                    HStack(alignment: .lastTextBaseline) {
                        WindowLabel(text: s.label)
                        Spacer(minLength: 2)
                        Percent(value: s.remainingPercent, size: 13, color: account.accent, weight: .medium)
                    }
                    .padding(.top, 6)
                } else if account.provider == .codex, let n = account.resetCredits, n > 0 {
                    HStack(alignment: .lastTextBaseline) {
                        WindowLabel(text: "RESET")
                        Spacer(minLength: 2)
                        Text("×\(n)").font(.system(size: 13, weight: .medium))
                    }
                    .padding(.top, 6)
                }
            } else {
                Text(account.error ?? "Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Medium / Extra large

private struct Columns: View {
    let accounts: [Account]
    let max: Int
    let now: Date
    let detailed: Bool

    var body: some View {
        let shown = Array(accounts.prefix(max))
        HStack(alignment: .top, spacing: detailed ? 18 : 12) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, a in
                if i > 0 { Divider() }
                Group {
                    if detailed {
                        CardColumn(account: a, all: accounts, now: now)
                    } else {
                        Column(account: a, all: accounts, now: now)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if accounts.count > max { MoreLabel(count: accounts.count - max) }
        }
    }
}

/// Medium widget: one account per column.
private struct Column: View {
    let account: Account
    let all: [Account]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ProviderLogo(provider: account.provider).frame(width: 15, height: 15)
                Text(all.count > 2 ? account.shortName(among: all) : account.provider.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(account.accent)
                    .lineLimit(1)
                StatusDot(account: account, now: now)
            }
            .padding(.bottom, 12)
            if let w = account.primary {
                WindowLabel(text: w.label)
                Percent(value: w.remainingPercent, size: 28, color: account.accent)
                UsageBar(fraction: w.remainingPercent / 100, pace: pace(w, now),
                         color: account.accent, thickness: 5)
                    .padding(.vertical, 2)
                Text(shortReset(w, now))
                    .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                Group {
                    if let s = account.secondary {
                        HStack {
                            WindowLabel(text: s.label)
                            Spacer(minLength: 2)
                            Percent(value: s.remainingPercent, size: 12, color: account.accent, weight: .medium)
                        }
                        UsageBar(fraction: s.remainingPercent / 100, pace: nil,
                                 color: account.accent, thickness: 3)
                    } else if account.provider == .codex, let n = account.resetCredits, n > 0 {
                        HStack {
                            WindowLabel(text: "RESET")
                            Spacer(minLength: 2)
                            Text("×\(n)").font(.system(size: 12, weight: .medium))
                        }
                    }
                }
                .padding(.top, 8)
            } else {
                Text(account.error ?? "Loading…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Extra-large widget: one app-style card per column.
private struct CardColumn: View {
    let account: Account
    let all: [Account]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ProviderLogo(provider: account.provider).frame(width: 24, height: 24)
                Text(account.provider.title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(account.accent)
                    .lineLimit(1)
                StatusDot(account: account, now: now)
            }
            if let plan = account.plan {
                Text(plan)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.top, 2)
            }
            if account.windows.isEmpty {
                Text(account.error ?? "Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.top, 14)
            }
            ForEach(Array(account.windows.enumerated()), id: \.offset) { i, w in
                if i > 0 { Divider().padding(.top, 10) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .lastTextBaseline) {
                        WindowLabel(text: w.label, size: 10.5)
                        Spacer()
                        Percent(value: w.remainingPercent, size: i == 0 ? 32 : 22, color: account.accent)
                    }
                    UsageBar(fraction: w.remainingPercent / 100, pace: pace(w, now),
                             color: account.accent, thickness: 6)
                    Text(Fmt.resets(w.resetsAt, now: now))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.top, 10)
            }
            if account.provider == .codex, !account.windows.isEmpty {
                Divider().padding(.top, 10)
                CodexExtras(account: account, size: 11).padding(.top, 8)
            }
            Spacer(minLength: 0)
            UpdatedLabel(account: account, now: now).font(.system(size: 10))
        }
    }
}

private struct CodexExtras: View {
    let account: Account
    let size: CGFloat

    var body: some View {
        HStack {
            Text("Reset").font(.system(size: size + 1))
            if let n = account.resetCredits, n > 0 {
                Text("×\(n)").font(.system(size: size)).foregroundStyle(.secondary)
            }
            Spacer()
            if let exp = account.expiresAt {
                Text("Expires \(Fmt.expires.string(from: exp))")
                    .font(.system(size: size)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

private struct UpdatedLabel: View {
    let account: Account
    let now: Date

    var body: some View {
        let warn = account.error != nil || account.isStale(now: now)
        Text(Fmt.updated(account.updatedAt, now: now))
            .foregroundStyle(warn ? Color.orange : Color.secondary)
            .lineLimit(1)
    }
}

// MARK: - Large

/// Large widget: one strip per account, its windows side by side.
private struct StripList: View {
    let accounts: [Account]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { i, a in
                if i > 0 { Divider().padding(.vertical, 10) }
                Strip(account: a, all: accounts, now: now)
            }
            Spacer(minLength: 6)
            footer
        }
    }

    /// Oldest update across accounts; orange if any account is failing or stale.
    private var footer: some View {
        let oldest = accounts.compactMap(\.updatedAt).min()
        let warn = accounts.contains { $0.error != nil || $0.isStale(now: now) }
        return HStack {
            Spacer()
            Text(Fmt.updated(oldest, now: now))
                .font(.system(size: 9.5))
                .foregroundStyle(warn ? Color.orange : Color.secondary)
        }
    }
}

private struct Strip: View {
    let account: Account
    let all: [Account]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProviderLogo(provider: account.provider).frame(width: 16, height: 16)
                Text(account.provider.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(account.accent)
                    .lineLimit(1)
                StatusDot(account: account, now: now)
                Spacer(minLength: 6)
                if let plan = account.plan {
                    Text(plan)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if account.windows.isEmpty {
                Text(account.error ?? "Loading…").font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(account.windows.prefix(2).enumerated()), id: \.offset) { _, w in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .lastTextBaseline) {
                                WindowLabel(text: w.label)
                                Spacer(minLength: 4)
                                Percent(value: w.remainingPercent, size: 20, color: account.accent)
                            }
                            UsageBar(fraction: w.remainingPercent / 100, pace: pace(w, now),
                                     color: account.accent, thickness: 5)
                            Text(shortReset(w, now))
                                .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if account.windows.count == 1 {
                        extras.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Fills the second column when an account has a single window (Codex).
    @ViewBuilder private var extras: some View {
        if account.provider == .codex {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .lastTextBaseline) {
                    WindowLabel(text: "RESET")
                    Spacer(minLength: 4)
                    Text("×\(account.resetCredits ?? 0)")
                        .font(.system(size: 20))
                        .foregroundStyle((account.resetCredits ?? 0) > 0 ? Color.primary : Color.secondary)
                }
                Spacer().frame(height: 11)
                if let exp = account.expiresAt {
                    Text("Expires \(Fmt.expires.string(from: exp))")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }
}
