import AppKit
import Combine
import ServiceManagement

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var isRefreshing = false

    private var timer: Timer?
    private var backoff: [String: Date] = [:]
    private var interval: TimeInterval = 60

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

            var results: [String: Result<Fetched, Error>] = [:]
            await withTaskGroup(of: (String, Result<Fetched, Error>).self) { group in
                for ref in refs where (skip[ref.id] ?? .distantPast) <= now {
                    group.addTask {
                        do { return (ref.id, .success(try await UsageAPI.fetch(ref))) }
                        catch { return (ref.id, .failure(error)) }
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
            isRefreshing = false
        }
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
        d.register(defaults: ["showWidget": true, "widgetOnTop": false, "refreshInterval": 60.0])
        showWidget = d.bool(forKey: "showWidget")
        widgetOnTop = d.bool(forKey: "widgetOnTop")
        refreshInterval = d.double(forKey: "refreshInterval")
    }
}
