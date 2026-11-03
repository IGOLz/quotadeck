import AppKit
import Combine
import SwiftUI

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
    private let popover = NSPopover()
    private var panel: NSPanel?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                                   accessibilityDescription: "QuotaDeck")
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.animates = true
        let hc = NSHostingController(rootView: PopoverView().environmentObject(store).environmentObject(settings))
        hc.sizingOptions = .preferredContentSize
        popover.contentViewController = hc

        store.start(interval: settings.refreshInterval)

        settings.$showWidget.sink { [weak self] show in self?.setWidget(visible: show) }.store(in: &bag)
        settings.$widgetOnTop.sink { [weak self] top in self?.applyLevel(onTop: top) }.store(in: &bag)
        settings.$refreshInterval.dropFirst().sink { [weak self] s in self?.store.setInterval(s) }.store(in: &bag)
        // Keep the widget's top edge fixed while its content grows or shrinks.
        store.$accounts.receive(on: RunLoop.main).sink { [weak self] _ in self?.fitPanel() }.store(in: &bag)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
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

let app = NSApplication.shared
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { runSnapshot(to: args[i + 1], dark: args.contains("--dark")) }
    app.run()
} else {
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
