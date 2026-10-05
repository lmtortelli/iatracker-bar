import BandejaIACore
import SwiftUI

/// Card **Limites**: uma seção por operador, uma linha por janela.
struct LimitsCard: View {
    let limits: [ProviderLimits]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Limites")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.secondary)

            if limits.isEmpty {
                Text("Consultando limites…")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondary)
            }

            ForEach(limits) { provider in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Swatch(color: Theme.color(for: provider.provider))
                        Text(provider.provider.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        SourceBadge(source: provider.source)
                    }
                    ForEach(provider.windows) { window in
                        LimitWindowRow(window: window, now: now)
                    }
                }
                .padding(.top, 8)
                .topSeparator()
            }
        }
        .card()
    }
}

private struct SourceBadge: View {
    let source: LimitSource

    var body: some View {
        Text(source.badge)
            .font(Theme.mono(10, .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundColor(source == .official ? Theme.officialBadgeText : Theme.secondary)
            .background(
                source == .official ? Theme.officialBadgeBackground : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
    }
}

/// Grade `116 | 1fr | 40`: rótulo + detalhe · barra + renovação · percentual.
struct LimitWindowRow: View {
    /// Dado oficial com mais de 6 min (duas consultas perdidas) é marcado como velho.
    static let staleAfter: TimeInterval = 6 * 60

    let window: LimitWindow
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(window.label).font(.system(size: 12))
                Text(detail)
                    .font(Theme.mono(10))
                    .foregroundColor(isStale ? Theme.warning : Theme.secondary)
                    .lineLimit(1)
            }
            .frame(width: 116, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                ThinBar(fraction: window.usedPct / 100, color: Theme.color(for: window.level))
                Text("↻ \(resetText)")
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.secondary)
                    .lineLimit(1)
            }

            Text("\(Int(window.usedPct))%")
                .font(Theme.mono(12, .semibold))
                .foregroundColor(window.level == .ok ? .primary : Theme.color(for: window.level))
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var isStale: Bool {
        window.source == .official && now.timeIntervalSince(window.updatedAt) > Self.staleAfter
    }

    private var detail: String {
        isStale ? "atualizado \(Formatters.ago(window.updatedAt, now: now))" : window.detail
    }

    private var resetText: String {
        window.level == .exceeded ? "limite atingido" : Formatters.reset(window.resetAt, now: now)
    }
}
