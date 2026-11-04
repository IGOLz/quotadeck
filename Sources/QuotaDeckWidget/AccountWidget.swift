import AppIntents
import QuotaDeckKit
import SwiftUI
import WidgetKit

// MARK: - Account picker (Edit Widget)

// The picker offers plain strings rather than an AppEntity: with this SwiftPM-built
// extension, App Intents could list entities but failed to resolve the chosen one back
// ("not a registered AppEntity identifier"), so every widget fell back to the default.
// A string goes through unchanged.

/// Picker labels for the accounts in the snapshot the app writes (no credentials).
enum AccountChoice {
    /// "Codex – ChatGPT Pro", "Claude Code – Claude Max 20x". Only if two accounts would
    /// read the same does the label add the email's name part, to tell them apart.
    static func labeled(_ accounts: [Account]) -> [(account: Account, label: String)] {
        let titles = accounts.map { a in a.plan.map { "\(a.provider.title) – \($0)" } ?? a.provider.title }
        return zip(accounts, titles).map { a, title in
            guard titles.filter({ $0 == title }).count > 1 else { return (a, title) }
            let name = a.email.split(separator: "@").first.map(String.init) ?? a.email
            return (a, "\(title) (\(name))")
        }
    }

    static func labels() -> [String] { labeled(SharedSnapshot.read()?.accounts ?? []).map(\.label) }

    /// The account a saved label points at. If the label no longer matches exactly (say the
    /// plan changed) but only one account of that provider exists, that one is meant.
    static func account(for label: String, in accounts: [Account]) -> Account? {
        if let hit = labeled(accounts).first(where: { $0.label == label }) { return hit.account }
        let sameProvider = accounts.filter { label.hasPrefix($0.provider.title) }
        return sameProvider.count == 1 ? sameProvider[0] : nil
    }
}

struct AccountOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] { AccountChoice.labels() }
    func defaultResult() async -> String? { AccountChoice.labels().first }
}

struct SelectAccountIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Account"
    static let description = IntentDescription("Choose which account this widget shows.")

    @Parameter(title: "Account", optionsProvider: AccountOptionsProvider())
    var account: String?

    init() {}
}

// MARK: - Timeline

struct AccountTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        let sample = QuotaEntry.sample()
        return QuotaEntry(date: sample.date, accounts: [sample.accounts[1]])
    }

    func snapshot(for configuration: SelectAccountIntent, in context: Context) async -> QuotaEntry {
        let entry = entry(for: configuration, snapshot: SharedSnapshot.read(), at: Date())
        return context.isPreview && entry.state != .ok ? placeholder(in: context) : entry
    }

    func timeline(for configuration: SelectAccountIntent, in context: Context) async -> Timeline<QuotaEntry> {
        let now = Date()
        let snapshot = SharedSnapshot.read()
        let entries = (0..<30).map { i in
            entry(for: configuration, snapshot: snapshot, at: now.addingTimeInterval(TimeInterval(i) * 120))
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private func entry(for configuration: SelectAccountIntent, snapshot: WidgetSnapshot?, at date: Date) -> QuotaEntry {
        guard let snapshot, !snapshot.accounts.isEmpty else {
            return QuotaEntry(date: date, accounts: [], state: .noData)
        }
        // Not configured yet: show the first account until one is chosen.
        guard let label = configuration.account else {
            return QuotaEntry(date: date, accounts: [snapshot.accounts[0]])
        }
        guard let account = AccountChoice.account(for: label, in: snapshot.accounts) else {
            return QuotaEntry(date: date, accounts: [], state: .missing)
        }
        return QuotaEntry(date: date, accounts: [account])
    }
}

struct QuotaAccountWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SharedSnapshot.accountWidgetKind,
                               intent: SelectAccountIntent.self,
                               provider: AccountTimeline()) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("QuotaDeck Account")
        .description("One account's remaining quota. Edit the widget to choose the account.")
        .supportedFamilies([.systemSmall])
    }
}
