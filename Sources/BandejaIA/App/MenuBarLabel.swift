import AppKit
import BandejaIACore
import SwiftUI

/// Item da barra de menus: bolinha de status + mini-barra do limite + `Claude 5h 63%`.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @AppStorage(Preferences.Key.menuBarMetric) private var metricRaw = MenuBarMetric.claude5h.rawValue

    var body: some View {
        let metric = MenuBarMetric(rawValue: metricRaw) ?? .claude5h
        let percent = state.menuBarPercent(metric)
        let text = percent.map { "\(metric.label) \(Int($0))%" } ?? "\(metric.label) –"

        HStack(spacing: 6) {
            Image(nsImage: StatusGlyph.image(active: !state.paused, percent: percent))
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .accessibilityLabel(state.paused ? "Bandeja IA pausado, \(text)" : "Bandeja IA, \(text)")
    }
}

/// A barra de menus só aceita imagem + texto: a bolinha e a mini-barra são desenhadas numa imagem colorida.
enum StatusGlyph {
    static func image(active: Bool, percent: Double?) -> NSImage {
        let size = NSSize(width: 36, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let dot = NSRect(x: 0, y: (size.height - 8) / 2, width: 8, height: 8)
            NSColor(hex: active ? 0x3FB56A : 0x8E9096).setFill()
            NSBezierPath(ovalIn: dot).fill()

            let track = NSRect(x: 14, y: (size.height - 5) / 2, width: 22, height: 5)
            NSColor.labelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()

            if let percent, percent > 0 {
                var fill = track
                fill.size.width = track.width * min(1, percent / 100)
                Theme.nsColor(for: LimitLevel(percent: percent)).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
