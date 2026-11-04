import QuotaDeckKit
import AppKit
import Combine
import SwiftUI
import WidgetKit

/// Borderless hosting view that lets the user drag the widget anywhere.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    let settings = Settings.shared
    private var statusItem: NSStatusItem!
    private lazy var statusMenu = StatusMenu(store: store, settings: settings)
    private var panel: NSPanel?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.menu = statusMenu.menu

        store.start(interval: settings.refreshInterval)

        settings.$showWidget.sink { [weak self] show in self?.setWidget(visible: show) }.store(in: &bag)
        settings.$widgetOnTop.sink { [weak self] top in self?.applyLevel(onTop: top) }.store(in: &bag)
        settings.$refreshInterval.dropFirst().sink { [weak self] s in self?.store.setInterval(s) }.store(in: &bag)
        // Keep the widget's top edge fixed while its content grows or shrinks.
        store.$accounts.receive(on: RunLoop.main).sink { [weak self] _ in self?.fitPanel() }.store(in: &bag)
    }

    /// Clicking the WidgetKit widget reopens the app: open the menu bar menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { [weak self] in self?.statusItem.button?.performClick(nil) }
        return false
    }

    // MARK: Desktop widget

    private func setWidget(visible: Bool) {
        if !visible { panel?.orderOut(nil); return }
        let p = panel ?? makePanel()
        panel = p
        applyLevel(onTop: settings.widgetOnTop)
        p.orderFrontRegardless()
        fitPanel()
    }

    private func makePanel() -> NSPanel {
        let root = WidgetView().environmentObject(store).environmentObject(settings)
        let host = DraggableHostingView(rootView: root)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 368, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        if !p.setFrameUsingName("QuotaDeckWidget"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: v.maxX - 368 - 8, y: v.maxY - 8))
        }
        p.setFrameAutosaveName("QuotaDeckWidget")
        return p
    }

    private func applyLevel(onTop: Bool) {
        panel?.level = onTop
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    private func fitPanel() {
        guard let p = panel, let host = p.contentView else { return }
        DispatchQueue.main.async {
            let size = host.fittingSize
            guard size.width > 0, size.height > 0, size != p.frame.size else { return }
            let top = p.frame.maxY
            p.setFrame(NSRect(x: p.frame.minX, y: top - size.height, width: size.width, height: size.height),
                       display: true)
        }
    }
}

// MARK: - Snapshot mode (renders the widget to a PNG with live data, for docs/testing)

@MainActor
func runSnapshot(to path: String, dark: Bool) {
    let store = UsageStore()
    store.refresh(force: true)
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
        MainActor.assumeIsolated {
            guard !store.isRefreshing else { return }
            t.invalidate()
            let view = WidgetView()
                .environmentObject(store)
                .environmentObject(Settings.shared)
                .background(dark ? Color(white: 0.05) : Color(white: 0.9))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
            }
            exit(0)
        }
    }
}

/// Renders the WidgetKit layouts (small, medium, large, extra large) side by side.
@MainActor
func runWidgetSnapshot(to path: String, dark: Bool) {
    let store = UsageStore()
    store.refresh(force: true)
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
        MainActor.assumeIsolated {
            guard !store.isRefreshing else { return }
            t.invalidate()
            let entry = QuotaEntry(date: Date(), accounts: store.accounts)
            // macOS 26+ desktop widget sizes, with the default content margins.
            let families: [(WidgetFamily, CGSize)] = [
                (.systemSmall, CGSize(width: 164, height: 164)),
                (.systemMedium, CGSize(width: 344, height: 164)),
                (.systemLarge, CGSize(width: 344, height: 344)),
                (.systemExtraLarge, CGSize(width: 704, height: 344)),
            ]
            let bg = dark ? Color(white: 0.11) : Color.white
            let tile = { (f: WidgetFamily, size: CGSize) in
                QuotaWidgetView(entry: entry, family: f)
                    .padding(16)
                    .frame(width: size.width, height: size.height)
                    .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(bg))
            }
            // One small per-account widget for each account (the configurable widget).
            let single = { (a: Account) in
                QuotaWidgetView(entry: QuotaEntry(date: entry.date, accounts: [a]), family: .systemSmall)
                    .padding(16)
                    .frame(width: 164, height: 164)
                    .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(bg))
            }
            let view = VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(entry.accounts) { single($0) }
                }
                HStack(alignment: .top, spacing: 20) {
                    ForEach(0..<3, id: \.self) { i in tile(families[i].0, families[i].1) }
                }
                tile(families[3].0, families[3].1)
            }
            .padding(24)
            .background(dark ? Color(red: 0.05, green: 0.12, blue: 0.25) : Color(red: 0.35, green: 0.55, blue: 0.8))
            .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
            }
            exit(0)
        }
    }
}

let app = NSApplication.shared
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--widget-snapshot"), i + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { runWidgetSnapshot(to: args[i + 1], dark: args.contains("--dark")) }
    app.run()
} else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { runSnapshot(to: args[i + 1], dark: args.contains("--dark")) }
    app.run()
} else {
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
