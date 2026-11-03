import SwiftUI

enum Theme {
    static let claude = Color(red: 0.80, green: 0.42, blue: 0.30)
    static let cardWidth: CGFloat = 336

    static func accent(_ p: Provider) -> Color {
        p == .claude ? claude : .primary
    }
}

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
        .help(account.email)
    }

    private func content(now: Date) -> some View {
        let accent = Theme.accent(account.provider)
        let rows = account.windows
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProviderLogo(provider: account.provider).frame(width: 30, height: 30)
                Text(account.provider.title)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(accent)
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

struct UsageBar: View {
    let fraction: Double
    let pace: Double?
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09)).frame(height: 7)
                Capsule().fill(color).frame(width: max(fraction > 0 ? 7 : 0, w * fraction), height: 7)
                if let pace {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary)
                        .frame(width: 2, height: 15)
                        .offset(x: min(w - 2, max(0, w * pace - 1)))
                }
            }
            .frame(height: 15)
        }
        .frame(height: 15)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

// MARK: - Logos

struct ProviderLogo: View {
    let provider: Provider

    var body: some View {
        switch provider {
        case .claude: ClaudeMark().stroke(Theme.claude, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        case .codex: CodexMark()
        }
    }
}

/// Starburst inspired by the Claude mark.
struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let lengths: [CGFloat] = [1, 0.82, 0.95, 0.78, 1, 0.86, 0.92, 0.8, 0.98, 0.84, 0.9, 0.79]
        var p = Path()
        for (i, l) in lengths.enumerated() {
            let a = Double(i) / Double(lengths.count) * 2 * .pi - .pi / 2
            p.move(to: CGPoint(x: c.x + cos(a) * r * 0.16, y: c.y + sin(a) * r * 0.16))
            p.addLine(to: CGPoint(x: c.x + cos(a) * r * l * 0.92, y: c.y + sin(a) * r * l * 0.92))
        }
        return p
    }
}

/// Terminal-prompt badge inspired by the Codex mark.
struct CodexMark: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.primary)
            Text(">_")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .offset(y: -0.5)
        }
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

/// The always-on desktop widget.
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
                Button("Hide Widget") { settings.showWidget = false }
            }
    }
}

/// Menu-bar popover: same cards plus controls.
struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: Settings

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                CardStack().padding(14)
            }
            .frame(maxHeight: 640)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 14) {
                Button {
                    store.refresh(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)

                Spacer()

                Menu {
                    Toggle("Show Desktop Widget", isOn: $settings.showWidget)
                    Toggle("Keep Widget on Top", isOn: $settings.widgetOnTop)
                    Picker("Refresh Every", selection: $settings.refreshInterval) {
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0)
                    }
                    Toggle("Launch at Login", isOn: Binding(
                        get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                    Divider()
                    Button("Quit QuotaDeck") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: Theme.cardWidth + 28)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
    }
}
