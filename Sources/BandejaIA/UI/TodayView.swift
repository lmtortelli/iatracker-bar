import BandejaIACore
import SwiftUI

/// Aba **Hoje**: sessão ativa, limites, total do dia e lista de sessões.
struct TodayView: View {
    @EnvironmentObject private var state: AppState
    let now: Date

    /// Sem rolagem na janela da barra de menus: listamos as mais recentes.
    private let maxSessions = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.paused {
                PausedCard()
            } else if let active = state.activeSession {
                ActiveSessionCard(session: active, now: now)
            } else {
                IdleCard()
            }

            LimitsCard(limits: state.limits, now: now)

            dayTotal

            sessionList
        }
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
    }

    // MARK: Total do dia

    @ViewBuilder
    private var dayTotal: some View {
        let summary = state.todaySummary(now: now)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hoje")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.secondary)
                Spacer()
                Text(Formatters.duration(summary.total))
                    .font(Theme.mono(13, .semibold))
            }

            StackedBar(segments: summary.byProvider.map {
                .init(id: $0.provider.rawValue, value: $0.seconds, color: Theme.color(for: $0.provider))
            })

            HStack(spacing: 14) {
                ForEach(summary.byProvider) { total in
                    HStack(spacing: 5) {
                        Swatch(color: Theme.color(for: total.provider), size: 7)
                        Text(total.provider.displayName)
                        Text(Formatters.duration(total.seconds)).font(Theme.mono(11))
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundColor(Theme.secondary)
        }
    }

    // MARK: Sessões

    @ViewBuilder
    private var sessionList: some View {
        let sessions = Array(state.todaySessions.reversed())
        VStack(spacing: 0) {
            ForEach(sessions.prefix(maxSessions)) { session in
                SessionRow(session: session, projectName: state.projectName(session.projectId), now: now)
            }
            if sessions.count > maxSessions {
                Text("+ \(sessions.count - maxSessions) sessões anteriores no Relatório")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                    .topSeparator()
            }
            if sessions.isEmpty {
                Text("Nenhuma sessão hoje.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                    .topSeparator()
            }
        }
    }
}

// MARK: - Cards de detecção

private struct ActiveSessionCard: View {
    @EnvironmentObject private var state: AppState
    let session: Session
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Theme.statusActive).frame(width: 6, height: 6)
                Text("DETECTANDO AGORA")
                    .font(.system(size: 11))
                    .tracking(0.55)
                    .foregroundColor(Theme.secondary)
            }

            HStack(spacing: 10) {
                ProviderIcon(provider: session.provider)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.provider.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(session.source)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Formatters.stopwatch(session.duration(now: now)))
                    .font(Theme.mono(17, .medium))
            }

            HStack(spacing: 8) {
                ProjectMenuButton(
                    projectName: state.projectName(session.projectId),
                    projects: state.projects,
                    onSelect: state.setActiveProject,
                    onCreate: state.createProjectForActiveSession
                )
                .fixedSize()

                Text(attribution)
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .card()
    }

    private var attribution: String {
        if session.manualProject { return "manual" }
        if let cwd = session.cwd { return "auto · \(cwd.abbreviatingHome())" }
        return "auto"
    }
}

private struct PausedCard: View {
    var body: some View {
        Text("Detecção pausada. Nenhum uso está sendo registrado.")
            .font(.system(size: 13))
            .foregroundColor(Theme.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }
}

private struct IdleCard: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.statusPaused).frame(width: 6, height: 6)
            Text("Nenhum uso de IA detectado agora.")
                .font(.system(size: 13))
                .foregroundColor(Theme.secondary)
        }
        .card()
    }
}
