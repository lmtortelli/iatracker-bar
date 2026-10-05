import Foundation

/// Dados fictícios equivalentes aos do protótipo (`design/Bandeja IA v2.dc.html`).
/// Usados no modo demonstração (`--demo` ou `BANDEJA_DEMO=1`).
public enum DemoData {
    public static let projects = ["Site Lumen", "App Finanças", "Pessoal"]
    private static let projectShare = [0.48, 0.37, 0.15]

    public enum Source {
        public static let claudeWeb = "claude.ai · Safari"
        public static let claudeApp = "App Claude"
        public static let claudeCode = "Claude Code · Terminal"
        public static let geminiWeb = "gemini.google.com · Chrome"
        public static let geminiCLI = "Gemini CLI · Terminal"
    }

    /// Sessões de hoje no protótipo: (origem, operador, projeto, início em minutos do dia, duração em minutos).
    private static let today: [(String, ProviderID, String, Int, Int)] = [
        (Source.geminiWeb, .gemini, "Pessoal", 8 * 60 + 42, 18),
        (Source.claudeCode, .claude, "App Finanças", 9 * 60 + 30, 72),
        (Source.claudeWeb, .claude, "Site Lumen", 11 * 60 + 5, 41),
        (Source.geminiCLI, .gemini, "Site Lumen", 12 * 60 + 40, 22),
        (Source.claudeApp, .claude, "Pessoal", 13 * 60 + 10, 28),
    ]
    /// No protótipo a sessão ativa começou às 14:20 e está em 12m34s.
    private static let activeStartMinute = 14 * 60 + 20
    private static let activeElapsed: TimeInterval = 754

    public static func activeStart(now: Date) -> Date {
        now.addingTimeInterval(-activeElapsed)
    }

    /// Popula o banco com 30 dias de uso e uma sessão ativa.
    public static func seed(_ database: AppDatabase, now: Date, calendar: Calendar = .current) throws {
        var ids: [String: Int64] = [:]
        for name in projects {
            ids[name] = try database.project(named: name).id
        }
        try database.insert(ProjectRule(projectId: ids["Site Lumen"] ?? 0, kind: .cwd, pattern: "~/dev/site-lumen"))
        try database.insert(ProjectRule(projectId: ids["App Finanças"] ?? 0, kind: .cwd, pattern: "~/dev/financas"))
        try database.insert(ProjectRule(projectId: ids["Pessoal"] ?? 0, kind: .domain, pattern: "gemini.google.com"))

        // Hoje: horários relativos à sessão ativa, para o cronômetro bater com o relógio real.
        let anchor = activeStart(now: now)
        for (source, provider, project, start, minutes) in today {
            let startedAt = anchor.addingTimeInterval(-Double(activeStartMinute - start) * 60)
            try database.insert(Session(
                provider: provider,
                source: source,
                projectId: ids[project],
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(Double(minutes) * 60)
            ))
        }
        try database.insert(Session(
            provider: .claude,
            source: Source.claudeCode,
            projectId: ids["Site Lumen"],
            cwd: "~/dev/site-lumen",
            startedAt: anchor
        ))

        // 29 dias anteriores com o mesmo gerador pseudoaleatório do protótipo.
        let todayStart = calendar.startOfDay(for: now)
        for back in 1..<30 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: todayStart) else { continue }
            let d = 29 - back
            let weekend = calendar.isDateInWeekend(day)
            let plan: [(ProviderID, Int, Int)] = [
                (.claude, Int((rnd(Double(d * 7)) * (weekend ? 30 : 160)).rounded()), 2 + Int((rnd(Double(d)) * 4).rounded())),
                (.gemini, Int((rnd(Double(d * 7 + 3)) * (weekend ? 15 : 55)).rounded()), 1 + Int((rnd(Double(d + 9)) * 3).rounded())),
            ]
            var cursor = day.addingTimeInterval(9 * 3600)
            for (provider, minutes, count) in plan where minutes > 0 {
                let each = Double(minutes) / Double(count)
                for i in 0..<count {
                    let project = pickProject((d + i) % 100)
                    try database.insert(Session(
                        provider: provider,
                        source: provider == .claude ? [Source.claudeCode, Source.claudeWeb, Source.claudeApp][i % 3] : [Source.geminiWeb, Source.geminiCLI][i % 2],
                        projectId: ids[project],
                        startedAt: cursor,
                        endedAt: cursor.addingTimeInterval(each * 60)
                    ))
                    cursor = cursor.addingTimeInterval(each * 60 + 15 * 60)
                }
            }
        }

        let quotaDay = GeminiQuota.quotaDay(for: now)
        try database.increment(.gemini, .webPrompts, day: quotaDay, by: 38)
        try database.increment(.gemini, .cliRequests, day: quotaDay, by: 212)
    }

    /// Limites do protótipo; a janela de 5 h sobe conforme a sessão ativa avança.
    public static func limits(
        now: Date,
        activeStart: Date,
        geminiQuota: Int,
        webPrompts: Int,
        cliRequests: Int
    ) -> [ProviderLimits] {
        let activeMinutes = max(0, now.timeIntervalSince(activeStart) / 60)
        let sessionStart = activeStart.addingTimeInterval(-195 * 60)
        let fiveHour = (52 + activeMinutes * 0.9).rounded()
        let weekly = (38 + activeMinutes * 0.15).rounded()
        let geminiReset = GeminiQuota.nextReset(after: now)
        let quota = max(1, geminiQuota)

        return [
            ProviderLimits(provider: .claude, source: .official, windows: [
                LimitWindow(
                    id: "five_hour", label: "Sessão 5 h", usedPct: fiveHour,
                    detail: "desde \(Formatters.time(sessionStart))",
                    resetAt: sessionStart.addingTimeInterval(5 * 3600), source: .official, updatedAt: now
                ),
                LimitWindow(
                    id: "seven_day", label: "Semanal", usedPct: weekly,
                    detail: "todos os modelos",
                    resetAt: nextThursdayNine(after: now), source: .official, updatedAt: now
                ),
            ]),
            ProviderLimits(provider: .gemini, source: .estimated, windows: [
                LimitWindow(
                    id: "app_daily", label: "App · diária",
                    usedPct: (Double(webPrompts) / Double(quota) * 100).rounded(),
                    detail: "\(webPrompts) de \(quota) prompts",
                    resetAt: geminiReset, source: .estimated, updatedAt: now
                ),
                LimitWindow(
                    id: "cli_daily", label: "CLI · diária",
                    usedPct: (Double(cliRequests) / Double(GeminiQuota.cliRequests) * 100).rounded(),
                    detail: "\(cliRequests) de \(GeminiQuota.cliRequests) req.",
                    resetAt: geminiReset, source: .estimated, updatedAt: now
                ),
            ]),
        ]
    }

    // MARK: Auxiliares

    private static func rnd(_ seed: Double) -> Double {
        let x = sin(seed * 9301 + 49297) * 233_280
        return x - x.rounded(.down)
    }

    private static func pickProject(_ seed: Int) -> String {
        let r = rnd(Double(seed) + 0.5)
        var acc = 0.0
        for (name, share) in zip(projects, projectShare) {
            acc += share
            if r < acc { return name }
        }
        return projects[0]
    }

    private static func nextThursdayNine(after now: Date) -> Date {
        let calendar = Calendar.current
        let components = DateComponents(hour: 9, minute: 0, weekday: 5)
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now
    }
}
