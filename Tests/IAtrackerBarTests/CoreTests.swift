import IAtrackerBarCore
import Foundation

enum FormattersTests {
    static let all: [TestCase] = [
        ("duração com horas", {
            expectEqual(Formatters.duration(3 * 3600 + 5 * 60), "3h 05m")
            expectEqual(Formatters.duration(41 * 60), "41m")
            expectEqual(Formatters.duration(0), "0m")
            expectEqual(Formatters.duration(89), "1m")
        }),
        ("cronômetro", {
            expectEqual(Formatters.stopwatch(754), "00:12:34")
            expectEqual(Formatters.stopwatch(3 * 3600 + 7), "03:00:07")
        }),
        ("dia da semana pt-BR", {
            // 5 out 2026 é segunda.
            expectEqual(Formatters.weekday(date(2026, 10, 5), calendar: testCalendar), "Seg")
            expectEqual(Formatters.weekday(date(2026, 10, 8), calendar: testCalendar), "Qui")
            expectEqual(Formatters.weekday(date(2026, 10, 11), calendar: testCalendar), "Dom")
        }),
        ("texto de renovação", {
            let now = date(2026, 10, 5, 14, 20)
            expectEqual(Formatters.reset(date(2026, 10, 5, 16, 5), now: now, calendar: testCalendar), "renova 16:05")
            expectEqual(Formatters.reset(date(2026, 10, 8, 9, 0), now: now, calendar: testCalendar), "renova Qui 09:00")
            // Amanhã, mas dentro de 24 h (cota do Gemini): só a hora.
            expectEqual(Formatters.reset(date(2026, 10, 6, 4, 0), now: now, calendar: testCalendar), "renova 04:00")
        }),
        ("há quanto tempo", {
            let now = date(2026, 10, 5, 14, 20)
            expectEqual(Formatters.ago(now.addingTimeInterval(-30), now: now), "agora")
            expectEqual(Formatters.ago(now.addingTimeInterval(-7 * 60), now: now), "há 7 min")
            expectEqual(Formatters.ago(now.addingTimeInterval(-125 * 60), now: now), "há 2 h")
        }),
    ]
}

enum ReportAggregatorTests {
    static let aggregator = ReportAggregator(calendar: testCalendar)

    static func session(_ provider: ProviderID, _ start: Date, minutes: Double?, project: Int64? = nil) -> Session {
        Session(
            provider: provider,
            source: "teste",
            projectId: project,
            startedAt: start,
            endedAt: minutes.map { start.addingTimeInterval($0 * 60) }
        )
    }

    static let all: [TestCase] = [
        ("hoje soma por operador e conta sessão ativa até agora", {
            let now = date(2026, 10, 5, 14, 32)
            let sessions = [
                session(.claude, date(2026, 10, 5, 9, 30), minutes: 72),
                session(.gemini, date(2026, 10, 5, 12, 40), minutes: 22),
                session(.claude, date(2026, 10, 5, 14, 20), minutes: nil),
            ]
            let summary = aggregator.today(sessions, now: now)
            expectClose(summary.total, Double(72 + 22 + 12) * 60)
            expectEqual(summary.byProvider.map(\.provider), [.claude, .gemini])
            expectEqual(summary.byProvider[0].sessions, 2)
            expectClose(summary.byProvider[0].seconds, 84 * 60)
        }),
        ("sessão que cruza a meia-noite é recortada", {
            let now = date(2026, 10, 5, 10, 0)
            let sessions = [session(.claude, date(2026, 10, 4, 23, 30), minutes: 60)]
            let summary = aggregator.today(sessions, now: now)
            expectClose(summary.total, 30 * 60)
            // Conta como sessão do dia em que começou.
            expectEqual(summary.byProvider[0].sessions, 0)
        }),
        ("semana vai de segunda a domingo e marca dias futuros", {
            let now = date(2026, 10, 7, 12, 0) // quarta
            let days = aggregator.days(for: .week, now: now)
            expectEqual(days.count, 7)
            expectEqual(days.first, date(2026, 10, 5))
            let report = aggregator.report([], projects: [:], range: .week, now: now)
            expectEqual(report.days.map(\.label), ["Seg", "Ter", "Qua", "Qui", "Sex", "Sáb", "Dom"])
            expectEqual(report.days.map(\.isFuture), [false, false, false, true, true, true, true])
        }),
        ("domingo pertence à semana que começou na segunda anterior", {
            let days = aggregator.days(for: .week, now: date(2026, 10, 11, 20, 0))
            expectEqual(days.first, date(2026, 10, 5))
        }),
        ("30 dias termina hoje e rotula a cada 5", {
            let now = date(2026, 10, 5, 12, 0)
            let report = aggregator.report([], projects: [:], range: .thirtyDays, now: now)
            expectEqual(report.days.count, 30)
            expectEqual(report.days.last?.date, date(2026, 10, 5))
            expectEqual(report.days.first?.date, date(2026, 9, 6))
            expectEqual(report.days[0].label, "6")
            expectEqual(report.days[1].label, "")
            expectEqual(report.days[5].label, "11")
        }),
        ("por projeto ordena do maior para o menor e agrupa sem projeto", {
            let now = date(2026, 10, 7, 18, 0)
            let sessions = [
                session(.claude, date(2026, 10, 5, 9, 0), minutes: 60, project: 1),
                session(.gemini, date(2026, 10, 6, 9, 0), minutes: 30, project: 1),
                session(.claude, date(2026, 10, 6, 11, 0), minutes: 120, project: 2),
                session(.gemini, date(2026, 10, 7, 9, 0), minutes: 10, project: nil),
                // Fora da semana.
                session(.claude, date(2026, 10, 1, 9, 0), minutes: 500, project: 1),
            ]
            let report = aggregator.report(sessions, projects: [1: "Site Lumen", 2: "App Finanças"], range: .week, now: now)
            expectEqual(report.byProject.map(\.name), ["App Finanças", "Site Lumen", ReportAggregator.noProject])
            expectClose(report.byProject[1].byProvider[.gemini] ?? 0, 30 * 60)
            expectClose(report.total, Double(60 + 30 + 120 + 10) * 60)
            expectEqual(report.byProvider.first { $0.provider == .claude }?.sessions, 2)
            expectClose(report.days[1].total, 150 * 60)
        }),
    ]
}

enum GeminiQuotaTests {
    static let all: [TestCase] = [
        ("renova à meia-noite do Pacífico", {
            // 5 out 2026 14:20 em São Paulo (UTC-3) = 10:20 em Los Angeles (UTC-7, horário de verão).
            let now = date(2026, 10, 5, 14, 20)
            let reset = GeminiQuota.nextReset(after: now)
            // Meia-noite de 6 out em LA = 04:00 em São Paulo.
            expectEqual(reset, date(2026, 10, 6, 4, 0))
            expectEqual(Formatters.time(reset, calendar: testCalendar), "04:00")
        }),
        ("dia de cota usa o fuso do Pacífico", {
            // 02:00 de 6 out em São Paulo ainda é 5 out em LA.
            expectEqual(GeminiQuota.quotaDay(for: date(2026, 10, 6, 2, 0)), "2026-10-05")
            expectEqual(GeminiQuota.quotaDay(for: date(2026, 10, 6, 5, 0)), "2026-10-06")
        }),
    ]
}

enum DatabaseTests {
    static let all: [TestCase] = [
        ("migra, insere e lê sessões do intervalo", {
            let db = try AppDatabase.inMemory()
            let project = try db.project(named: "Site Lumen")
            expect(project.id != nil)
            expectEqual(try db.project(named: "Site Lumen").id, project.id)

            try db.insert(Session(provider: .claude, source: "a", projectId: project.id, startedAt: date(2026, 10, 4, 23, 0), endedAt: date(2026, 10, 5, 1, 0)))
            try db.insert(Session(provider: .gemini, source: "b", startedAt: date(2026, 10, 5, 9, 0), endedAt: date(2026, 10, 5, 9, 30)))
            try db.insert(Session(provider: .claude, source: "c", startedAt: date(2026, 10, 5, 14, 0)))
            try db.insert(Session(provider: .claude, source: "d", startedAt: date(2026, 10, 3, 9, 0), endedAt: date(2026, 10, 3, 10, 0)))

            let today = try db.sessions(from: date(2026, 10, 5), to: date(2026, 10, 6))
            expectEqual(today.map(\.source), ["a", "b", "c"])
            expectEqual(try db.openSessions().map(\.source), ["c"])
        }),
        ("contador acumula por dia", {
            let db = try AppDatabase.inMemory()
            try db.increment(.gemini, .cliRequests, day: "2026-10-05")
            try db.increment(.gemini, .cliRequests, day: "2026-10-05", by: 4)
            try db.increment(.gemini, .cliRequests, day: "2026-10-06")
            expectEqual(try db.counter(.gemini, .cliRequests, day: "2026-10-05"), 5)
            expectEqual(try db.counter(.gemini, .webPrompts, day: "2026-10-05"), 0)
        }),
        ("último snapshot por janela", {
            let db = try AppDatabase.inMemory()
            try db.insert(LimitSnapshot(provider: .claude, window: "five_hour", usedPct: 10, resetAt: nil, source: .official, fetchedAt: date(2026, 10, 5, 10, 0)))
            try db.insert(LimitSnapshot(provider: .claude, window: "five_hour", usedPct: 40, resetAt: nil, source: .official, fetchedAt: date(2026, 10, 5, 11, 0)))
            try db.insert(LimitSnapshot(provider: .claude, window: "seven_day", usedPct: 20, resetAt: nil, source: .official, fetchedAt: date(2026, 10, 5, 9, 0)))
            let latest = try db.latestSnapshots(for: .claude).sorted { $0.window < $1.window }
            expectEqual(latest.map(\.usedPct), [40, 20])
        }),
        ("renomear projeto e juntar com um de mesmo nome", {
            let db = try AppDatabase.inMemory()
            let a = try db.project(named: "site-lumen")
            let b = try db.project(named: "Site Lumen")
            try db.insert(Session(provider: .claude, source: "x", projectId: a.id, startedAt: date(2026, 10, 5, 9, 0), endedAt: date(2026, 10, 5, 10, 0)))
            try db.insert(ProjectRule(projectId: a.id ?? 0, kind: .cwd, pattern: "~/dev/site-lumen"))

            // Renomear simples.
            let renamed = try db.renameProject(id: try db.project(named: "Avulso").id ?? 0, to: "Pessoal")
            expect(try db.projects().contains { $0.id == renamed && $0.name == "Pessoal" })

            // Nome já existe: junta em "Site Lumen".
            let merged = try db.renameProject(id: a.id ?? 0, to: "Site Lumen")
            expectEqual(merged, b.id)
            expectEqual(try db.projects().map(\.name).sorted(), ["Pessoal", "Site Lumen"])
            expectEqual(try db.sessions(from: date(2026, 10, 5), to: date(2026, 10, 6)).first?.projectId, b.id)
            expectEqual(try db.rules().first?.projectId, b.id)
        }),
        ("excluir projeto mantém sessões sem projeto e remove regras", {
            let db = try AppDatabase.inMemory()
            let a = try db.project(named: "A")
            try db.insert(Session(provider: .claude, source: "x", projectId: a.id, startedAt: date(2026, 10, 5, 9, 0), endedAt: date(2026, 10, 5, 10, 0)))
            try db.insert(ProjectRule(projectId: a.id ?? 0, kind: .title, pattern: "A"))
            try db.deleteProject(id: a.id ?? 0)
            let sessions = try db.sessions(from: date(2026, 10, 5), to: date(2026, 10, 6))
            expectEqual(sessions.count, 1)
            expect(sessions.first?.projectId == nil)
            expectEqual(try db.rules().count, 0)
        }),
        ("dados de demonstração populam 30 dias", {
            let db = try AppDatabase.inMemory()
            let now = date(2026, 10, 5, 14, 32)
            try DemoData.seed(db, now: now, calendar: testCalendar)
            expectEqual(try db.projects().count, 3)
            expectEqual(try db.openSessions().count, 1)
            let month = try db.sessions(from: date(2026, 9, 6), to: date(2026, 10, 6))
            expect(month.count > 30, "esperava várias sessões, obtido \(month.count)")
        }),
    ]
}
