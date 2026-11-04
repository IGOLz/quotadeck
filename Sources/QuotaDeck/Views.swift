import QuotaDeckKit
import SwiftUI

// MARK: - Card

struct AccountCard: View {
    let account: Account
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            content(now: ctx.date)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(width: Theme.cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(scheme == .dark ? Color(white: 0.13) : .white)
                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.12 : 0.05), lineWidth: 0.5)
        )
    }

    private func content(now: Date) -> some View {
        let accent = Theme.accent(account.provider)
        let rows = account.windows
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProviderLogo(provider: account.provider).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.provider.title)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(accent)
                    if let plan = account.plan {
                        Text(plan).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.bottom, 10)

            if rows.isEmpty {
                Text(account.error ?? "Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { i, w in
                if i > 0 { Divider().padding(.vertical, 2) }
                UsageRow(window: w, accent: accent, prominent: i == 0, now: now,
                         footer: i == rows.count - 1 ? updated(now) : nil)
            }

            if account.provider == .codex && !rows.isEmpty {
                Divider().padding(.vertical, 6)
                HStack(spacing: 6) {
                    Text("Reset").font(.system(size: 12.5))
                    if let n = account.resetCredits, n > 0 {
                        Text("×\(n)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let exp = account.expiresAt {
                        Text("Expires \(Fmt.expires.string(from: exp))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)
            }
        }
    }

    private func updated(_ now: Date) -> some View {
        Text(Fmt.updated(account.updatedAt, now: now))
            .font(.system(size: 10.5))
            .foregroundStyle(account.error == nil ? Color.secondary : Color.orange)
            .help(account.error ?? "")
    }
}

struct UsageRow<Footer: View>: View {
    let window: UsageWindow
    let accent: Color
    let prominent: Bool
    let now: Date
    let footer: Footer?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .lastTextBaseline) {
                Text(window.label)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.percent(window.remainingPercent))
                    .font(.system(size: prominent ? 34 : 22, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(accent)
            }
            UsageBar(fraction: window.remainingPercent / 100,
                     pace: window.kind == .weekly ? window.paceFraction(now: now) : nil,
                     color: accent)
            HStack {
                Text(Fmt.resets(window.resetsAt, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let footer { footer }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Containers

struct CardStack: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(spacing: 12) {
            if store.accounts.isEmpty {
                Text(store.isRefreshing ? "Loading accounts…" : "No Claude or Codex accounts found")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: Theme.cardWidth, height: 80)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.background))
            }
            ForEach(store.accounts) { AccountCard(account: $0) }
        }
    }
}

/// The optional floating panel (the WidgetKit widget lives in the extension).
struct WidgetView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: Settings

    var body: some View {
        CardStack()
            .padding(16) // room for shadows
            .contextMenu {
                Button("Refresh Now") { store.refresh(force: true) }
                Toggle("Keep on Top of Windows", isOn: $settings.widgetOnTop)
                Divider()
                Button("Hide Floating Panel") { settings.showWidget = false }
            }
    }
}
