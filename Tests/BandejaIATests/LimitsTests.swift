import BandejaIACore
import Foundation

enum ClaudeLimitsTests {
    static let all: [TestCase] = [
        ("parser lê janelas, ignora nulas e chaves extras", {
            let fetched = date(2026, 10, 5, 14, 20)
            let snapshots = try ClaudeLimits.parse(try fixture("claude_usage.synthetic.json"), fetchedAt: fetched)
            expectEqual(snapshots.map(\.window), ["five_hour", "seven_day"])
            expectEqual(snapshots.map(\.usedPct), [63, 40])
            expectEqual(snapshots.first?.source, .official)
            // 19:05 UTC = 16:05 em São Paulo; fração de microssegundos aceita.
            expectEqual(snapshots.first?.resetAt, date(2026, 10, 5, 16, 5))
        }),
        ("parser rejeita resposta sem janelas", {
            do {
                _ = try ClaudeLimits.parse(Data(#"{"error":{"type":"x"}}"#.utf8), fetchedAt: .now)
                expect(false, "deveria falhar")
            } catch let error as ClaudeLimits.ParseError {
                expectEqual(error, .noWindows)
            }
            do {
                _ = try ClaudeLimits.parse(Data("<html>".utf8), fetchedAt: .now)
                expect(false, "deveria falhar")
            } catch let error as ClaudeLimits.ParseError {
                expectEqual(error, .notJSON)
            }
        }),
        ("janela pronta: rótulo, detalhe e renovação vencida", {
            let reset = date(2026, 10, 5, 16, 5)
            let snapshot = LimitSnapshot(provider: .claude, window: "five_hour", usedPct: 63, resetAt: reset, source: .official, fetchedAt: date(2026, 10, 5, 14, 0))
            let window = ClaudeLimits.window(from: snapshot, now: date(2026, 10, 5, 14, 20))
            expectEqual(window.label, "Sessão 5 h")
            expectEqual(window.detail, "desde \(Formatters.time(reset.addingTimeInterval(-5 * 3600)))")
            expectEqual(window.usedPct, 63)

            let after = ClaudeLimits.window(from: snapshot, now: date(2026, 10, 5, 16, 30))
            expectEqual(after.usedPct, 0)
            expectEqual(after.detail, "renovada")

            let weekly = ClaudeLimits.limits(from: [
                LimitSnapshot(provider: .claude, window: "seven_day", usedPct: 40, resetAt: nil, source: .official, fetchedAt: .now),
                snapshot,
            ], now: date(2026, 10, 5, 14, 20))
            expectEqual(weekly.windows.map(\.id), ["five_hour", "seven_day"])
        }),
    ]
}

enum ClaudeEstimatorTests {
    static let all: [TestCase] = [
        ("soma as últimas 5 horas e renova 5 h após a primeira hora ativa", {
            // 17:20 UTC.
            let now = Date(timeIntervalSince1970: 1_791_220_800 + 20 * 60)
            let keys = ClaudeEstimator.hourKeys(now: now)
            expectEqual(keys.count, 5)
            expectEqual(keys.last, TokenBuckets.hourKey(now))
            let usage = [keys[0]: 1_000_000, keys[2]: 1_000_000, "fora-da-janela": 9_000_000]
            let limits = ClaudeEstimator.estimate(tokensByHour: usage, budget: 4_000_000, now: now)
            let window = limits.windows[0]
            expectEqual(limits.source, .estimated)
            expectEqual(window.usedPct, 50)
            expectEqual(window.detail, "2,0 mi tokens")
            // Primeira hora ativa = início da hora de keys[0] (4 h atrás); renova 5 h depois.
            let firstHour = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - 4 * 3600) / 3600).rounded(.down) * 3600)
            expectEqual(window.resetAt, firstHour.addingTimeInterval(5 * 3600))
        }),
        ("sem tokens: 0% e sem renovação", {
            let limits = ClaudeEstimator.estimate(tokensByHour: [:], budget: 4_000_000, now: .now)
            expectEqual(limits.windows[0].usedPct, 0)
            expect(limits.windows[0].resetAt == nil)
        }),
        ("calibração exige uso mínimo", {
            expectEqual(ClaudeEstimator.calibratedBudget(tokens: 500_000, utilization: 25), 2_000_000)
            expect(ClaudeEstimator.calibratedBudget(tokens: 500_000, utilization: 2) == nil)
            expect(ClaudeEstimator.calibratedBudget(tokens: 0, utilization: 50) == nil)
        }),
        ("formata tokens", {
            expectEqual(ClaudeEstimator.formatTokens(850), "850")
            expectEqual(ClaudeEstimator.formatTokens(12_400), "12 mil")
            expectEqual(ClaudeEstimator.formatTokens(1_250_000), "1,2 mi")
        }),
    ]
}

enum GeminiLimitsTests {
    static let all: [TestCase] = [
        ("prompts web estimados por sessões do dia de cota", {
            let now = date(2026, 10, 5, 14, 0)
            let sessions = [
                Session(provider: .gemini, source: "gemini.google.com · Chrome", startedAt: date(2026, 10, 5, 9, 0)),
                Session(provider: .gemini, source: "aistudio.google.com · Arc", startedAt: date(2026, 10, 5, 10, 0)),
                Session(provider: .gemini, source: "Gemini CLI · Terminal", startedAt: date(2026, 10, 5, 11, 0)),
                Session(provider: .claude, source: "claude.ai · Safari", startedAt: date(2026, 10, 5, 11, 0)),
                // 03:00 em São Paulo = 23:00 do dia anterior em Los Angeles: outro dia de cota.
                Session(provider: .gemini, source: "gemini.google.com · Chrome", startedAt: date(2026, 10, 5, 3, 0)),
            ]
            expectEqual(GeminiLimits.estimatedWebPrompts(sessions: sessions, now: now, promptsPerSession: 4), 8)
        }),
        ("janelas diárias", {
            let limits = GeminiLimits.limits(now: date(2026, 10, 5, 14, 0), webPrompts: 38, quota: 100, cliRequests: 212)
            expectEqual(limits.windows.map(\.id), ["app_daily", "cli_daily"])
            expectEqual(limits.windows.map(\.usedPct), [38, 21])
            expectEqual(limits.windows[0].detail, "38 de 100 prompts")
            expectEqual(limits.windows[1].detail, "212 de 1000 req.")
            expectEqual(limits.windows[0].resetAt, date(2026, 10, 6, 4, 0))
        }),
    ]
}

enum LimitAlertsTests {
    static func limits(_ pct: Double, reset: Date? = date(2026, 10, 5, 16, 5)) -> [ProviderLimits] {
        [ProviderLimits(provider: .claude, source: .official, windows: [
            LimitWindow(id: "five_hour", label: "Sessão 5 h", usedPct: pct, detail: "", resetAt: reset, source: .official, updatedAt: .now),
        ])]
    }

    static let all: [TestCase] = [
        ("abaixo de 80%: nada", {
            let (alerts, keys) = LimitAlerts.due(limits(79), alreadySent: [])
            expect(alerts.isEmpty && keys.isEmpty)
        }),
        ("80% avisa uma vez por período", {
            let first = LimitAlerts.due(limits(82), alreadySent: [])
            expectEqual(first.alerts.map(\.threshold), [80])
            let again = LimitAlerts.due(limits(85), alreadySent: first.keys)
            expect(again.alerts.isEmpty)
            // Novo período de renovação: avisa de novo.
            let next = LimitAlerts.due(limits(85, reset: date(2026, 10, 5, 21, 5)), alreadySent: first.keys)
            expectEqual(next.alerts.count, 1)
        }),
        ("pular direto para 100% avisa só 100% e marca 80%", {
            let jump = LimitAlerts.due(limits(100), alreadySent: [])
            expectEqual(jump.alerts.map(\.threshold), [100])
            expectEqual(jump.keys.count, 2)
            let later = LimitAlerts.due(limits(100), alreadySent: jump.keys)
            expect(later.alerts.isEmpty)
        }),
        ("depois de 80%, chegar a 100% avisa de novo", {
            let eighty = LimitAlerts.due(limits(80), alreadySent: [])
            let hundred = LimitAlerts.due(limits(100), alreadySent: eighty.keys)
            expectEqual(hundred.alerts.map(\.threshold), [100])
        }),
    ]
}
