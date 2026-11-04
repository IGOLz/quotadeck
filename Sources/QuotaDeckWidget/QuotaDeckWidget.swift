import QuotaDeckKit
import SwiftUI
import WidgetKit

/// Reads the snapshot QuotaDeck.app writes after every refresh. The app asks
/// WidgetKit to reload whenever the numbers change; in between, the timeline
/// steps forward so reset countdowns and the pace marker keep moving.
struct QuotaTimeline: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        let entry = current(at: Date())
        completion(context.isPreview && entry.state == .noData ? .sample() : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedSnapshot.read()
        let entries = (0..<30).map { i in
            entry(snapshot, at: now.addingTimeInterval(TimeInterval(i) * 120))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func current(at date: Date) -> QuotaEntry { entry(SharedSnapshot.read(), at: date) }

    private func entry(_ snapshot: WidgetSnapshot?, at date: Date) -> QuotaEntry {
        guard let snapshot else { return QuotaEntry(date: date, accounts: [], state: .noData) }
        return QuotaEntry(date: date, accounts: snapshot.accounts)
    }
}

struct QuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedSnapshot.widgetKind, provider: QuotaTimeline()) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("QuotaDeck")
        .description("Remaining Claude Code and Codex quota for every account.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct QuotaDeckWidgets: WidgetBundle {
    var body: some Widget {
        QuotaAccountWidget()
        QuotaWidget()
    }
}
