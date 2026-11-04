import SwiftUI
import WidgetKit

public enum Theme {
    public static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)  // #D97757, Claude brand orange
    public static let cardWidth: CGFloat = 336

    public static func accent(_ p: Provider) -> Color {
        p == .claude ? claude : .primary
    }
}

// MARK: - Bar

public struct UsageBar: View {
    let fraction: Double
    let pace: Double?
    let color: Color
    let thickness: CGFloat

    public init(fraction: Double, pace: Double?, color: Color, thickness: CGFloat = 7) {
        self.fraction = fraction
        self.pace = pace
        self.color = color
        self.thickness = thickness
    }

    public var body: some View {
        let tick = thickness * 2 + 1
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09)).frame(height: thickness)
                Capsule().fill(color)
                    .frame(width: max(fraction > 0 ? thickness : 0, w * fraction), height: thickness)
                    .widgetAccentable()
                if let pace {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary)
                        .frame(width: thickness > 5 ? 2 : 1.5, height: tick)
                        .offset(x: min(w - 2, max(0, w * pace - 1)))
                }
            }
            .frame(height: tick)
        }
        .frame(height: tick)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

// MARK: - Logos

/// Official provider mark; scales with the frame it is given.
public struct ProviderLogo: View {
    let provider: Provider

    public init(provider: Provider) { self.provider = provider }

    public var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            switch provider {
            case .claude:
                ClaudeSpark().fill(Theme.claude).widgetAccentable()
            case .codex:
                if let logo = Logos.codex {
                    Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    CodexMark(size: size)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Fallback when the bundled Codex logo is missing (e.g. a bare `swift run`).
struct CodexMark: View {
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle().fill(Color.primary)
            Text(">_")
                .font(.system(size: size * 0.4, weight: .bold, design: .monospaced))
                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                .offset(y: -size * 0.017)
        }
        .frame(width: size, height: size)
    }
}
