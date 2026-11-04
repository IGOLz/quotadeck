// Draws the QuotaDeck app icon and writes Resources/AppIcon.icns (plus a 1024px PNG).
//   swift scripts/assets/make-app-icon.swift [outdir]
// A gauge running from Claude orange to Codex blue around a deck of quota bars.
import AppKit
import SwiftUI

let claude = Color(red: 0.851, green: 0.467, blue: 0.341)  // #D97757
let codex = Color(red: 0.36, green: 0.40, blue: 1.0)

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: 824pt body on a 1024pt canvas.
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.15, green: 0.16, blue: 0.27),
                                              Color(red: 0.05, green: 0.055, blue: 0.11)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 4)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 12)

            gauge.frame(width: 560, height: 560).offset(y: 14)

            VStack(alignment: .leading, spacing: 30) {
                bar(width: 214, color: .white)
                bar(width: 162, color: .white.opacity(0.72))
                bar(width: 108, color: .white.opacity(0.46))
            }
            .frame(width: 214, alignment: .leading)
            .offset(y: 14)
        }
        .frame(width: 1024, height: 1024)
    }

    /// 270° arc with the gap at the bottom; the filled part is ~70%.
    private var gauge: some View {
        let line = StrokeStyle(lineWidth: 70, lineCap: .round)
        return ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.10), style: line)
            Circle().trim(from: 0, to: 0.75 * 0.70)
                .stroke(AngularGradient(colors: [claude, Color(red: 0.80, green: 0.45, blue: 0.62), codex],
                                        center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(270 * 0.70)),
                        style: line)
        }
        .rotationEffect(.degrees(135))
    }

    private func bar(width: CGFloat, color: Color) -> some View {
        Capsule().fill(color).frame(width: width, height: 38)
    }
}

@MainActor
func render(size: Int) -> Data {
    let r = ImageRenderer(content: Icon().scaleEffect(CGFloat(size) / 1024).frame(width: CGFloat(size), height: CGFloat(size)))
    r.scale = 1
    let cg = r.cgImage!
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    for base in [16, 32, 128, 256, 512] {
        try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    try! render(size: 1024).write(to: outDir.appendingPathComponent("AppIcon.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print("wrote \(outDir.path)/AppIcon.icns and AppIcon.png")
