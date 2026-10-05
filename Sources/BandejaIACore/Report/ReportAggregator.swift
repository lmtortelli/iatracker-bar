import Foundation

public enum ReportRange: String, CaseIterable, Sendable {
    /// Segunda a domingo da semana corrente (dias futuros aparecem vazios).
    case week
    /// Últimos 30 dias, terminando hoje.
    case thirtyDays

    public var title: String {
        switch self {
        case .week: "Semana"
        case .thirtyDays: "30 dias"
        }
    }
}

public struct DayBar: Equatable, Identifiable, Sendable {
    public var date: Date
    public var label: String
    public var isFuture: Bool
    public var byProvider: [ProviderID: TimeInterval]

    public var id: Date { date }
    public var total: TimeInterval { byProvider.values.reduce(0, +) }
}

public struct ProviderTotal: Equatable, Identifiable, Sendable {
    public var provider: ProviderID
    public var sessions: Int
    public var seconds: TimeInterval
    public var id: ProviderID { provider }
}

public struct ProjectTotal: Equatable, Identifiable, Sendable {
    public var name: String
    public var byProvider: [ProviderID: TimeInterval]
    public var id: String { name }
    public var total: TimeInterval { byProvider.values.reduce(0, +) }
}

public struct Report: Equatable, Sendable {
    public var range: ReportRange
    public var days: [DayBar]
    public var byProvider: [ProviderTotal]
    public var byProject: [ProjectTotal]

    public var total: TimeInterval { byProvider.reduce(0) { $0 + $1.seconds } }
}

public struct TodaySummary: Equatable, Sendable {
    public var total: TimeInterval
    public var byProvider: [ProviderTotal]
}

/// Agregações puras sobre sessões: sem banco, sem relógio implícito.
public struct ReportAggregator {
    public static let noProject = "Sem projeto"

    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Intervalo de datas (início de cada dia) coberto pelo relatório.
    public func days(for range: ReportRange, now: Date) -> [Date] {
        let today = calendar.startOfDay(for: now)
        switch range {
        case .week:
            // weekday: 1 = domingo … 7 = sábado → recuar até segunda.
            let offset = (calendar.component(.weekday, from: today) + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
        case .thirtyDays:
            return (0..<30).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        }
    }

    public func today(_ sessions: [Session], now: Date) -> TodaySummary {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        let totals = providerTotals(sessions, from: start, to: end, now: now)
        return TodaySummary(total: totals.reduce(0) { $0 + $1.seconds }, byProvider: totals)
    }

    public func report(
        _ sessions: [Session],
        projects: [Int64: String],
        range: ReportRange,
        now: Date
    ) -> Report {
        let dayStarts = days(for: range, now: now)
        let today = calendar.startOfDay(for: now)
        guard let first = dayStarts.first, let last = dayStarts.last,
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: last)
        else {
            return Report(range: range, days: [], byProvider: [], byProject: [])
        }

        let bars = dayStarts.enumerated().map { index, day -> DayBar in
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            var byProvider: [ProviderID: TimeInterval] = [:]
            for session in sessions {
                let seconds = overlap(session, from: day, to: next, now: now)
                if seconds > 0 { byProvider[session.provider, default: 0] += seconds }
            }
            let label: String
            switch range {
            case .week: label = Formatters.weekdaysMondayFirst[index]
            case .thirtyDays: label = index % 5 == 0 ? String(calendar.component(.day, from: day)) : ""
            }
            return DayBar(date: day, label: label, isFuture: day > today, byProvider: byProvider)
        }

        var projectTotals: [String: [ProviderID: TimeInterval]] = [:]
        for session in sessions {
            let seconds = overlap(session, from: first, to: rangeEnd, now: now)
            guard seconds > 0 else { continue }
            let name = session.projectId.flatMap { projects[$0] } ?? Self.noProject
            projectTotals[name, default: [:]][session.provider, default: 0] += seconds
        }
        let byProject = projectTotals
            .map { ProjectTotal(name: $0.key, byProvider: $0.value) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }

        return Report(
            range: range,
            days: bars,
            byProvider: providerTotals(sessions, from: first, to: rangeEnd, now: now),
            byProject: byProject
        )
    }

    // MARK: Auxiliares

    /// Totais por operador (todos os operadores, mesmo zerados, na ordem de `ProviderID.allCases`).
    /// Sessões contam no dia em que começaram; o tempo é recortado ao intervalo.
    func providerTotals(_ sessions: [Session], from start: Date, to end: Date, now: Date) -> [ProviderTotal] {
        ProviderID.allCases.map { provider in
            let mine = sessions.filter { $0.provider == provider }
            return ProviderTotal(
                provider: provider,
                sessions: mine.filter { $0.startedAt >= start && $0.startedAt < end }.count,
                seconds: mine.reduce(0) { $0 + overlap($1, from: start, to: end, now: now) }
            )
        }
    }

    func overlap(_ session: Session, from start: Date, to end: Date, now: Date) -> TimeInterval {
        let sessionEnd = min(session.endedAt ?? now, now)
        let lower = max(session.startedAt, start)
        let upper = min(sessionEnd, end)
        return max(0, upper.timeIntervalSince(lower))
    }
}
