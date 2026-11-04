import QuotaDeckKit
import AppKit
import Combine
import ServiceManagement
import WidgetKit

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var isRefreshing = false

    private var timer: Timer?
    private var backoff: [String: Date] = [:]
    /// Claude plans come from a separate endpoint; checked at start and then every 6 hours.
    private var planCheckedAt: [String: Date] = [:]
    private var interval: TimeInterval = 60
    private let widget = WidgetPublisher()

    func start(interval: TimeInterval) {
        setInterval(interval)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Network needs a moment after wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.refresh(force: true) }
        }
        refresh(force: true)
    }

    func setInterval(_ seconds: TimeInterval) {
        interval = max(15, seconds)
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Refreshes all accounts concurrently. Accounts that were rate limited are
    /// skipped until their backoff expires, unless `force` is set.
    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let skip = force ? [:] : backoff

        Task {
            let refs = await Task.detached(priority: .utility) { Discovery.accounts() }.value
            let now = Date()
            let needPlan = Set(refs.filter {
                $0.provider == .claude && (planCheckedAt[$0.id] ?? .distantPast) < now.addingTimeInterval(-6 * 3_600)
            }.map(\.id))

            var results: [String: Result<Fetched, Error>] = [:]
            await withTaskGroup(of: (String, Result<Fetched, Error>).self) { group in
                for ref in refs where (skip[ref.id] ?? .distantPast) <= now {
                    group.addTask {
                        do {
                            var f = try await UsageAPI.fetch(ref)
                            if needPlan.contains(ref.id) { f.plan = await UsageAPI.claudePlan(ref) }
                            return (ref.id, .success(f))
                        } catch { return (ref.id, .failure(error)) }
                    }
                }
                for await (id, r) in group { results[id] = r }
            }

            let previous = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            accounts = refs.map { ref in
                var acc = previous[ref.id] ?? Account(id: ref.id, provider: ref.provider, email: ref.email)
                acc.email = ref.email
                switch results[ref.id] {
                case .success(let f)?:
                    acc.windows = f.windows
                    acc.resetCredits = f.resetCredits
                    acc.expiresAt = f.expiresAt
                    if let e = f.email { acc.email = e }
                    if let p = f.plan {
                        acc.plan = p
                        planCheckedAt[ref.id] = Date()
                    } else if needPlan.contains(ref.id) {
                        // Profile lookup failed: try again in ~10 minutes.
                        planCheckedAt[ref.id] = Date().addingTimeInterval(-6 * 3_600 + 600)
                    }
                    // Claude Ultra has no 5-hour limit, only the weekly one.
                    if acc.provider == .claude, acc.plan?.localizedCaseInsensitiveContains("ultra") == true {
                        acc.windows.removeAll { $0.kind == .fiveHour }
                    }
                    acc.updatedAt = Date()
                    acc.error = nil
                    backoff[ref.id] = nil
                case .failure(let e)?:
                    acc.error = e.localizedDescription
                    if (e as? FetchError)?.isRateLimit == true {
                        backoff[ref.id] = Date().addingTimeInterval(300)
                    }
                case nil:
                    break
                }
                return acc
            }
            widget.publish(accounts)
            isRefreshing = false
        }
    }
}

/// Hands fresh data to the WidgetKit extension. The snapshot file is rewritten on
/// every refresh, but WidgetKit is only asked to redraw when something visible
/// changed, at most once a minute, so the system's reload budget lasts all day.
@MainActor
final class WidgetPublisher {
    private var lastSignature = ""
    private var lastReload = Date.distantPast
    private var pending: DispatchWorkItem?

    func publish(_ accounts: [Account]) {
        try? SharedSnapshot.write(WidgetSnapshot(accounts: accounts))
        let sig = signature(accounts)
        guard sig != lastSignature else { return }
        lastSignature = sig

        pending?.cancel()
        let wait = lastReload.addingTimeInterval(60).timeIntervalSinceNow
        let work = DispatchWorkItem { [weak self] in
            self?.lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wait), execute: work)
    }

    /// What the widget shows, minus the clock-driven parts its timeline handles itself.
    private func signature(_ accounts: [Account]) -> String {
        accounts.map { a in
            let windows = a.windows.map { w in
                "\(w.label)=\(Fmt.percent(w.remainingPercent))@\(Int((w.resetsAt?.timeIntervalSince1970 ?? 0) / 60))"
            }
            return "\(a.id)|\(a.plan ?? "")|\(windows.joined(separator: ","))|\(a.resetCredits ?? -1)|"
                + "\(a.expiresAt.map { Int($0.timeIntervalSince1970 / 86_400) } ?? -1)|\(a.error == nil)"
        }.joined(separator: ";")
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var showWidget: Bool { didSet { d.set(showWidget, forKey: "showWidget") } }
    @Published var widgetOnTop: Bool { didSet { d.set(widgetOnTop, forKey: "widgetOnTop") } }
    @Published var refreshInterval: Double { didSet { d.set(refreshInterval, forKey: "refreshInterval") } }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    private init() {
        d.register(defaults: ["showWidget": false, "widgetOnTop": false, "refreshInterval": 60.0])
        showWidget = d.bool(forKey: "showWidget")
        widgetOnTop = d.bool(forKey: "widgetOnTop")
        refreshInterval = d.double(forKey: "refreshInterval")
    }
}
