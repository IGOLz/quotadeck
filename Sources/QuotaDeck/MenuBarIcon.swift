import AppKit

/// The app icon's gauge and quota bars as a menu bar template image.
enum MenuBarIcon {
    static func image() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let c = NSPoint(x: 9, y: 8.6)
            let r: CGFloat = 7
            func arc(from start: CGFloat, to end: CGFloat, alpha: CGFloat) {
                let p = NSBezierPath()
                p.appendArc(withCenter: c, radius: r, startAngle: start, endAngle: end, clockwise: true)
                p.lineWidth = 2
                p.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                p.stroke()
            }
            // 270° gauge with the gap at the bottom, filled ~70% clockwise from lower left.
            arc(from: 225, to: -45, alpha: 0.35)
            arc(from: 225, to: 225 - 270 * 0.7, alpha: 1)
            NSColor.black.setFill()
            for (i, w) in [6.0, 4.4, 2.8].enumerated() {
                NSBezierPath(roundedRect: NSRect(x: 6.1, y: 10.2 - Double(i) * 2.4, width: w, height: 1.4),
                             xRadius: 0.7, yRadius: 0.7).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "QuotaDeck"
        return img
    }
}
