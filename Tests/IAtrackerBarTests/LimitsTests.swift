import IAtrackerBarCore
import Foundation

enum ClaudeLimitsTests {
    static let all: [TestCase] = [
        ("parser lê a resposta real (anonimizada) do endpoint de uso", {
            let fetched = date(2026, 10, 5, 20, 59)
            let snapshots = try ClaudeLimits.parse(try fixture("claude_usage.json"), fetchedAt: fetched)
            // Janelas por modelo vêm nulas; dezenas de chaves extras são ignoradas.
            expectEqual(snapshots.map(\.window), ["five_hour", "seven_day"])
            expectEqual(snapshots.map(\.usedPct), [92, 11])
            expectEqual(snapshots.first?.source, .official)
            // 00:20 UTC de 6 out = 21:20 de 5 out em São Paulo; microssegundos no ISO 8601.
            expectEqual(snapshots.first.flatMap(\.resetAt).map { Int($0.timeIntervalSince(date(2026, 10, 5, 21, 20))) }, 0)
            expectEqual(snapshots.last.flatMap(\.resetAt).map { Int($0.timeIntervalSince(date(2026, 10, 12, 2, 0))) }, 0)
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
    static let reset = date(2026, 10, 5, 21, 20)

    static func limits(_pct: Double, window: String = "five_hour", reset: Date? = LimitAlertsTests.reset) -> [ProviderLimits] {
        [ProviderLimits(provider: .claude, source: .official, windows: [
            LimitWindow(id: window, label: window == "five_hour" ? "Sessão 5 h" : "Semanal", usedPct: _pct, detail: "", resetAt: reset, source: .official, updatedAt: .now),
        ])]
    }

    static func run(_ pct: Double, at now: Date, settings: AlertSettings = AlertSettings(), window: String = "five_hour", reset: Date? = LimitAlertsTests.reset, state: inout AlertState) -> [LimitAlerts.Alert] {
        LimitAlerts.evaluate(limits(_pct: pct, window: window, reset: reset), settings: settings, state: &state, now: now)
    }

    static let t = date(2026, 10, 5, 18, 0)

    static let all: [TestCase] = [
        ("abaixo do limite configurado: nada", {
            var state = AlertState()
            expect(run(79, at: t, state: &state).isEmpty)
            var custom = AlertSettings()
            custom.nearThreshold = 90
            expect(run(85, at: t, settings: custom, state: &state).isEmpty)
        }),
        ("perto do limite avisa uma vez por período", {
            var state = AlertState()
            let first = run(82, at: t, state: &state)
            expectEqual(first.map(\.kind), [.near(threshold: 80)])
            expectEqual(first.first?.title, "Claude · Sessão 5 h em 82%")
            expect(run(85, at: t.addingTimeInterval(60), state: &state).isEmpty)
            // Período seguinte avisa de novo.
            let next = run(85, at: t.addingTimeInterval(60), reset: date(2026, 10, 6, 2, 20), state: &state)
            expectEqual(next.count, 1)
        }),
        ("semanal também avisa e pode ser desligada", {
            var state = AlertState()
            let weekly = run(81, at: t, window: "seven_day", reset: date(2026, 10, 12, 2, 0), state: &state)
            expectEqual(weekly.first?.title, "Claude · Semanal em 81%")
            var only5h = AlertSettings()
            only5h.windows = ["five_hour"]
            var other = AlertState()
            expect(run(95, at: t, settings: only5h, window: "seven_day", reset: date(2026, 10, 12, 2, 0), state: &other).isEmpty)
        }),
        ("pular direto para 100% avisa só 100%", {
            var state = AlertState()
            expectEqual(run(100, at: t, state: &state).map(\.kind), [.full])
            expect(run(100, at: t.addingTimeInterval(60), state: &state).isEmpty)
        }),
        ("100% desligado: só o aviso de perto", {
            var state = AlertState()
            var settings = AlertSettings()
            settings.fullEnabled = false
            expectEqual(run(100, at: t, settings: settings, state: &state).map(\.kind), [.near(threshold: 80)])
        }),
        ("renovação avisa quando o pico passou de 90%", {
            var state = AlertState()
            _ = run(93, at: t, state: &state)
            _ = run(97, at: t.addingTimeInterval(1800), state: &state)
            // Depois da renovação a janela volta zerada e sem horário.
            let renewed = run(0, at: reset.addingTimeInterval(60), reset: nil, state: &state)
            expectEqual(renewed.map(\.kind), [.reset(peak: 97)])
            expectEqual(renewed.first?.title, "Claude · Sessão 5 h renovou")
            expect(run(0, at: reset.addingTimeInterval(120), reset: nil, state: &state).isEmpty)
        }),
        ("renovação não avisa se o pico ficou abaixo do configurado", {
            var state = AlertState()
            _ = run(85, at: t, state: &state)
            expect(run(0, at: reset.addingTimeInterval(60), reset: nil, state: &state).isEmpty)

            var custom = AlertSettings()
            custom.resetThreshold = 80
            var other = AlertState()
            _ = run(85, at: t, settings: custom, state: &other)
            expectEqual(run(0, at: reset.addingTimeInterval(60), settings: custom, reset: nil, state: &other).count, 1)
        }),
        ("renovação desligada ou muito antiga não avisa", {
            var settings = AlertSettings()
            settings.resetEnabled = false
            var state = AlertState()
            _ = run(99, at: t, settings: settings, state: &state)
            expect(run(0, at: reset.addingTimeInterval(60), settings: settings, reset: nil, state: &state).isEmpty)

            var stale = AlertState()
            _ = run(99, at: t, state: &stale)
            expect(run(0, at: reset.addingTimeInterval(7 * 3600), reset: nil, state: &stale).isEmpty)
            expect(stale.peaks.isEmpty)
        }),
        ("estado sobrevive a codificação", {
            var state = AlertState()
            _ = run(95, at: t, state: &state)
            let decoded = try JSONDecoder().decode(AlertState.self, from: JSONEncoder().encode(state))
            expectEqual(decoded, state)
        }),
    ]
}
