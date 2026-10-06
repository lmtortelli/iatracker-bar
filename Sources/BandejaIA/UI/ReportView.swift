import BandejaIACore
import SwiftUI

/// Aba **Relatório**: semana ou 30 dias, por operador e por projeto.
struct ReportView: View {
    @EnvironmentObject private var state: AppState
    let now: Date

    private let maxProjects = 6

    var body: some View {
        let report = state.report(now: now)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 4) {
                    ForEach(ReportRange.allCases, id: \.self) { range in
                        RangeButton(title: range.title, isOn: state.reportRange == range) {
                            state.reportRange = range
                        }
                    }
                }
                Spacer()
                Text(Formatters.duration(report.total))
                    .font(Theme.mono(13, .semibold))
            }

            if report.total == 0 {
                Text("Ainda não há uso registrado neste período. Use o Claude ou o Gemini normalmente: o relatório se monta sozinho.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                DayBarChart(days: report.days, gap: report.range == .week ? 8 : 2)
                    .frame(height: 120)

                providerTable(report)

                projectList(report)
            }
        }
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
    }

    private func providerTable(_ report: Report) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Por operador").frame(maxWidth: .infinity, alignment: .leading)
                Text("Sessões").frame(width: 64, alignment: .trailing)
                Text("Tempo").frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 11))
            .foregroundColor(Theme.secondary)
            .padding(.bottom, 4)

            ForEach(report.byProvider) { total in
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Swatch(color: Theme.color(for: total.provider))
                        Text(total.provider.displayName)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(total.sessions)")
                        .font(Theme.mono(12, .medium))
                        .foregroundColor(Theme.secondary)
                        .frame(width: 64, alignment: .trailing)
                    Text(Formatters.duration(total.seconds))
                        .font(Theme.mono(12, .medium))
                        .frame(width: 64, alignment: .trailing)
                }
                .font(.system(size: 13))
                .padding(.vertical, 7)
                .topSeparator()
            }
        }
    }

    private func projectList(_ report: Report) -> some View {
        let projects = Array(report.byProject.prefix(maxProjects))
        let largest = projects.first?.total ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            Text("Por projeto")
                .font(.system(size: 11))
                .foregroundColor(Theme.secondary)

            if projects.isEmpty {
                Text("Nenhum uso no período.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondary)
            }

            ForEach(projects) { project in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(project.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(Formatters.duration(project.total)).font(Theme.mono(12, .medium))
                    }
                    GeometryReader { geo in
                        StackedBar(
                            segments: ProviderID.allCases.map {
                                .init(id: $0.rawValue, value: project.byProvider[$0] ?? 0, color: Theme.color(for: $0))
                            },
                            height: 5
                        )
                        .frame(width: largest > 0 ? geo.size.width * project.total / largest : 0)
                    }
                    .frame(height: 5)
                }
            }
        }
    }
}

private struct RangeButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundColor(isOn ? Theme.rangeActiveText : .primary)
                .background(
                    isOn ? Theme.rangeActiveBackground : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Barras verticais empilhadas por operador (Claude embaixo).
private struct DayBarChart: View {
    let days: [DayBar]
    let gap: CGFloat

    var body: some View {
        let maxTotal = max(days.map(\.total).max() ?? 0, 1)

        HStack(alignment: .bottom, spacing: gap) {
            ForEach(days) { day in
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            column(day, height: geo.size.height * (day.isFuture ? 0.02 : day.total / maxTotal))
                        }
                    }
                    Text(day.label)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: 12)
                }
                .help("\(Formatters.weekday(day.date)) \(Formatters.shortDate(day.date)) · \(Formatters.duration(day.total))")
            }
        }
    }

    @ViewBuilder
    private func column(_ day: DayBar, height: CGFloat) -> some View {
        if day.isFuture || day.total == 0 {
            Rectangle().fill(Theme.track).frame(height: day.isFuture ? max(height, 2) : 0)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            VStack(spacing: 0) {
                ForEach(ProviderID.allCases.reversed(), id: \.self) { provider in
                    let value = day.byProvider[provider] ?? 0
                    Rectangle()
                        .fill(Theme.color(for: provider))
                        .frame(height: height * value / day.total)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }
}
