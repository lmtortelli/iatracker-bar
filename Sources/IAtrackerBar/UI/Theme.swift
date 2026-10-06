import AppKit
import IAtrackerBarCore
import SwiftUI

/// Tokens de design do handoff (`design/README.md`).
enum Theme {
    static let claude = Color(hex: 0xCC7A50)
    static let gemini = Color(hex: 0x9168C9)

    static let ok = Color(hex: 0x4A9D63)
    static let warning = Color(hex: 0xD69A2B)
    static let error = Color(hex: 0xD9483E)

    static let statusActive = Color(hex: 0x3FB56A)
    static let statusPaused = Color(hex: 0x8E9096)

    static let cardBackground = Color.dynamic(light: NSColor.white, dark: NSColor.white.withAlphaComponent(0.07))
    static let cardBorder = Color.primary.opacity(0.06)
    static let separator = Color.primary.opacity(0.06)
    static let track = Color.primary.opacity(0.08)
    static let secondary = Color.dynamic(light: NSColor(hex: 0x6B6E75), dark: NSColor(hex: 0xA0A3AA))

    static let officialBadgeBackground = Color.dynamic(light: NSColor(hex: 0xE3F4E8), dark: NSColor(hex: 0x4A9D63).withAlphaComponent(0.22))
    static let officialBadgeText = Color.dynamic(light: NSColor(hex: 0x2F6E44), dark: NSColor(hex: 0x8BD3A0))

    static let rangeActiveBackground = Color.dynamic(light: NSColor(hex: 0x2E3036), dark: NSColor(hex: 0xE6E7EA))
    static let rangeActiveText = Color.dynamic(light: NSColor.white, dark: NSColor(hex: 0x1E2026))

    static func color(for provider: ProviderID) -> Color {
        switch provider {
        case .claude: claude
        case .gemini: gemini
        }
    }

    static func color(for level: LimitLevel) -> Color {
        switch level {
        case .ok: ok
        case .warning: warning
        case .exceeded: error
        }
    }

    static func nsColor(for level: LimitLevel) -> NSColor {
        switch level {
        case .ok: NSColor(hex: 0x4A9D63)
        case .warning: NSColor(hex: 0xD69A2B)
        case .exceeded: NSColor(hex: 0xD9483E)
        }
    }

    /// Números usam SF Mono no lugar do JetBrains Mono do protótipo.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Componentes visuais compartilhados

struct CardModifier: ViewModifier {
    var spacing: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cardBorder))
    }
}

extension View {
    func card() -> some View {
        modifier(CardModifier())
    }

    /// Separador de 1px no topo, como as linhas de lista do protótipo.
    func topSeparator() -> some View {
        overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }
}

/// Quadrado colorido com a inicial do operador (sem logos oficiais).
struct ProviderIcon: View {
    let provider: ProviderID
    var size: CGFloat = 30
    var radius: CGFloat = 8
    var fontSize: CGFloat = 14

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.color(for: provider))
            .frame(width: size, height: size)
            .overlay(
                Text(provider.initial)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(.white)
            )
            .accessibilityHidden(true)
    }
}

/// Quadradinho de legenda.
struct Swatch: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// Barra de progresso fina (trilho + preenchimento).
struct ThinBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}

/// Barra horizontal empilhada, segmentos proporcionais com espaço entre eles.
struct StackedBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 6
    var gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let visible = segments.filter { $0.value > 0 }
            let total = visible.reduce(0) { $0 + $1.value }
            let usable = max(0, geo.size.width - gap * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: gap) {
                if total == 0 {
                    Rectangle().fill(Theme.track)
                } else {
                    ForEach(visible) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: usable * segment.value / total)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .frame(height: height)
    }
}
