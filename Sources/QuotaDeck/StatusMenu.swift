import AppKit
import Combine
import QuotaDeckKit
import SwiftUI

/// The menu bar extra: a real NSMenu, like the system's Battery or Wi-Fi menus.
/// Accounts are SwiftUI rows inside menu items; everything else is native menu items.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let width: CGFloat = 300

    private let store: UsageStore
    private let settings: Settings
    let menu = NSMenu()

    init(store: UsageStore, settings: Settings) {
        self.store = store
        self.settings = settings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuWillOpen(_ menu: NSMenu) { store.refresh() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(hosted(MenuHeader()))
        menu.addItem(.separator())

        if store.accounts.isEmpty {
            menu.addItem(hosted(MenuEmptyRow()))
        }
        for (i, account) in store.accounts.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            menu.addItem(hosted(MenuAccountRow(id: account.id)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Refresh Now", key: "r", action: #selector(refreshNow)))
        menu.addItem(refreshIntervalItem())
        menu.addItem(.separator())
        menu.addItem(item("Show Floating Panel", action: #selector(toggleFloatingPanel), on: settings.showWidget))
        let onTop = item("Keep Panel on Top", action: #selector(togglePanelOnTop), on: settings.widgetOnTop)
        onTop.isEnabled = settings.showWidget
        onTop.indentationLevel = 1
        menu.addItem(onTop)
        menu.addItem(item("Launch at Login", action: #selector(toggleLaunchAtLogin), on: settings.launchAtLogin))
        menu.addItem(.separator())
        menu.addItem(item("Quit QuotaDeck", key: "q", action: #selector(quit)))
    }

    // MARK: Items

    private func hosted(_ view: some View) -> NSMenuItem {
        let host = NSHostingView(rootView: view
            .frame(width: Self.width, alignment: .leading)
            .environmentObject(store))
        host.frame.size = host.fittingSize
        let item = NSMenuItem()
        item.view = host
        return item
    }

    private func item(_ title: String, key: String = "", action: Selector, on: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let on { item.state = on ? .on : .off }
        return item
    }

    private func refreshIntervalItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Refresh Every", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, seconds) in [("30 Seconds", 30.0), ("1 Minute", 60.0), ("2 Minutes", 120.0), ("5 Minutes", 300.0)] {
            let i = item(title, action: #selector(setInterval(_:)), on: settings.refreshInterval == seconds)
            i.representedObject = seconds
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    // MARK: Actions

    @objc private func refreshNow() { store.refresh(force: true) }
    @objc private func setInterval(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? Double { settings.refreshInterval = s }
    }
    @objc private func toggleFloatingPanel() { settings.showWidget.toggle() }
    @objc private func togglePanelOnTop() { settings.widgetOnTop.toggle() }
    @objc private func toggleLaunchAtLogin() { settings.launchAtLogin.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Rows

/// Bold title with the refresh status on the right, like the Battery menu's header.
private struct MenuHeader: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(alignment: .firstTextBaseline) {
                Text("QuotaDeck").font(.system(size: 13, weight: .bold))
                Spacer()
                status(now: ctx.date)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    @ViewBuilder private func status(now: Date) -> some View {
        let failing = store.accounts.filter { $0.error != nil }.count
        if store.isRefreshing {
            Text("Updating…").foregroundStyle(.secondary)
        } else if failing > 0 {
            Label(failing == 1 ? "1 account not updated" : "\(failing) accounts not updated",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Text(Fmt.updated(store.accounts.compactMap(\.updatedAt).min(), now: now))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MenuEmptyRow: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        Text(store.isRefreshing ? "Loading accounts…" : "No Claude or Codex accounts found")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
    }
}

/// One account: logo, name and plan, then each quota window with a system progress bar.
/// Reads the account from the store by id so it stays live while the menu is open.
private struct MenuAccountRow: View {
    let id: String
    @EnvironmentObject var store: UsageStore

    var body: some View {
        if let account = store.accounts.first(where: { $0.id == id }) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                content(account, now: ctx.date)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
    }

    private func content(_ a: Account, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ProviderLogo(provider: a.provider).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(a.provider.title).font(.system(size: 13, weight: .semibold))
                    Text(a.plan ?? " ").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let error = a.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(error)
                }
            }

            if a.windows.isEmpty {
                Text(a.error ?? "Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Array(a.windows.enumerated()), id: \.offset) { _, w in
                WindowRow(window: w, tint: MenuTheme.tint(a.provider), now: now)
            }

            if a.provider == .codex, !a.windows.isEmpty, (a.resetCredits ?? 0) > 0 || a.expiresAt != nil {
                HStack {
                    if let n = a.resetCredits, n > 0 {
                        Text(n == 1 ? "1 rate-limit reset" : "\(n) rate-limit resets")
                    }
                    Spacer()
                    if let exp = a.expiresAt { Text("Active until \(Fmt.expires.string(from: exp))") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let tint: Color
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(MenuTheme.title(window)).font(.system(size: 12))
                Spacer()
                Text("\(Fmt.percent(window.remainingPercent)) left")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            // System progress bars lose their tint inside a vibrant menu; this one keeps
            // the provider colour and shows the steady-pace mark on the weekly window.
            UsageBar(fraction: window.remainingPercent / 100,
                     pace: window.kind == .weekly ? window.paceFraction(now: now) : nil,
                     color: tint, thickness: 5)
            Text(Fmt.resets(window.resetsAt, now: now))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Snapshot

/// The menu as one SwiftUI view, for `--menu-snapshot` (README screenshots). The account
/// rows are the real ones; the native items are drawn to match NSMenu's layout.
struct MenuSnapshot: View {
    let settings: Settings
    @EnvironmentObject var store: UsageStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuHeader()
            separator
            ForEach(Array(store.accounts.enumerated()), id: \.element.id) { i, account in
                if i > 0 { separator }
                MenuAccountRow(id: account.id)
            }
            separator
            item("Refresh Now", shortcut: "⌘R")
            item("Refresh Every", submenu: true)
            separator
            item("Show Floating Panel", checked: settings.showWidget)
            item("Keep Panel on Top", checked: settings.widgetOnTop, enabled: settings.showWidget)
            item("Launch at Login", checked: settings.launchAtLogin)
            separator
            item("Quit QuotaDeck", shortcut: "⌘Q")
        }
        .padding(.vertical, 6)
        .frame(width: StatusMenu.width)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            .padding(.horizontal, 14).padding(.vertical, 5)
    }

    private func item(_ title: String, shortcut: String? = nil, submenu: Bool = false,
                      checked: Bool = false, enabled: Bool = true) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                .frame(width: 15).opacity(checked ? 1 : 0)
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            if submenu { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)) }
        }
        .font(.system(size: 13))
        .foregroundStyle(enabled ? .primary : .tertiary)
        .padding(.horizontal, 14)
        .frame(height: 22)
    }
}

enum MenuTheme {
    static func tint(_ p: Provider) -> Color {
        p == .claude ? Theme.claude : Color(red: 0.30, green: 0.36, blue: 1.0)  // Codex logo blue
    }

    static func title(_ w: UsageWindow) -> String {
        switch w.kind {
        case .weekly: "Weekly"
        case .fiveHour: "5 hours"
        case .other(let s): s >= 86_400 ? "\(Int(s / 86_400)) days" : "\(Int(s / 3_600)) hours"
        }
    }
}
