import Foundation

/// Janelas de limite do Claude e o parser da resposta de uso.
///
/// Endpoint **não documentado** (frágil): `GET https://api.anthropic.com/api/oauth/usage`
/// (token OAuth do Claude Code) ou `GET https://claude.ai/api/organizations/{org}/usage` (cookie `sessionKey`).
/// Formato confirmado em 05/10/2026 (fixture `Tests/Fixtures/claude_usage.json`):
/// `{"five_hour": {"utilization": 0–100, "resets_at": ISO 8601 com microssegundos, …}, "seven_day": {…},
///   "seven_day_opus": null, "seven_day_sonnet": null, …dezenas de chaves extras, "limits": […], "spend": {…}}`
public enum ClaudeLimits {
    public static let fiveHour = "five_hour"
    public static let sevenDay = "seven_day"

    /// Janelas conhecidas, na ordem de exibição.
    static let known: [(id: String, label: String, detail: String?)] = [
        (fiveHour, "Sessão 5 h", nil),
        (sevenDay, "Semanal", "todos os modelos"),
        ("seven_day_opus", "Semanal · Opus", "só Opus"),
        ("seven_day_sonnet", "Semanal · Sonnet", "só Sonnet"),
    ]

    public enum ParseError: Error, Equatable {
        case notJSON
        case noWindows
    }

    /// Converte a resposta em snapshots (um por janela presente e não nula).
    public static func parse(_ data: Data, fetchedAt: Date) throws -> [LimitSnapshot] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        let snapshots: [LimitSnapshot] = known.compactMap { window in
            guard let entry = json[window.id] as? [String: Any],
                  let utilization = (entry["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            return LimitSnapshot(
                provider: .claude,
                window: window.id,
                usedPct: utilization,
                resetAt: (entry["resets_at"] as? String).flatMap(ISO8601.parse),
                source: .official,
                fetchedAt: fetchedAt
            )
        }
        guard snapshots.contains(where: { $0.window == fiveHour || $0.window == sevenDay }) else {
            throw ParseError.noWindows
        }
        return snapshots
    }

    /// Janela pronta para exibir a partir do último snapshot.
    /// Se a renovação já passou, o uso é zerado até a próxima consulta.
    public static func window(from snapshot: LimitSnapshot, now: Date) -> LimitWindow {
        let meta = known.first { $0.id == snapshot.window }
        let renewed = snapshot.resetAt.map { $0 <= now } ?? false
        let detail: String
        if snapshot.window == fiveHour, let reset = snapshot.resetAt, !renewed {
            detail = "desde \(Formatters.time(reset.addingTimeInterval(-5 * 3600)))"
        } else {
            detail = meta?.detail ?? ""
        }
        return LimitWindow(
            id: snapshot.window,
            label: meta?.label ?? snapshot.window,
            usedPct: renewed ? 0 : snapshot.usedPct,
            detail: renewed ? "renovada" : detail,
            resetAt: renewed ? nil : snapshot.resetAt,
            source: snapshot.source,
            updatedAt: snapshot.fetchedAt
        )
    }

    public static func limits(from snapshots: [LimitSnapshot], now: Date, note: String? = nil) -> ProviderLimits {
        let order = known.map(\.id)
        let windows = snapshots
            .sorted { (order.firstIndex(of: $0.window) ?? 99) < (order.firstIndex(of: $1.window) ?? 99) }
            .map { window(from: $0, now: now) }
        return ProviderLimits(provider: .claude, source: .official, windows: windows, note: note)
    }
}

/// Estimativa da janela de 5 h pelos tokens do Claude Code (sem credencial ou sem consulta válida).
public enum ClaudeEstimator {
    /// Orçamento usado até haver calibração com um dado oficial. Valor arbitrário, ajustável.
    public static let defaultBudget = 4_000_000

    /// Chaves horárias (UTC) das últimas 5 h, incluindo a hora corrente.
    public static func hourKeys(now: Date) -> [String] {
        (0..<5).map { TokenBuckets.hourKey(now.addingTimeInterval(-Double($0) * 3600)) }.reversed()
    }

    public static func estimate(tokensByHour: [String: Int], budget: Int, now: Date, note: String? = nil) -> ProviderLimits {
        let keys = hourKeys(now: now)
        let tokens = keys.reduce(0) { $0 + (tokensByHour[$1] ?? 0) }
        let firstActiveHour = keys.firstIndex { (tokensByHour[$0] ?? 0) > 0 }
            .map { now.addingTimeInterval(-Double(keys.count - 1 - $0) * 3600) }
            .map(startOfHour)
        let window = LimitWindow(
            id: ClaudeLimits.fiveHour,
            label: "Sessão 5 h",
            usedPct: (Double(tokens) / Double(max(1, budget)) * 100).rounded(),
            detail: "\(formatTokens(tokens)) tokens",
            resetAt: firstActiveHour.map { $0.addingTimeInterval(5 * 3600) },
            source: .estimated,
            updatedAt: now
        )
        return ProviderLimits(provider: .claude, source: .estimated, windows: [window], note: note)
    }

    /// Orçamento implícito: tokens locais da janela ÷ uso oficial. Só com uso ≥ 5% para não amplificar ruído.
    public static func calibratedBudget(tokens: Int, utilization: Double) -> Int? {
        guard utilization >= 5, tokens > 0 else { return nil }
        return Int((Double(tokens) / (utilization / 100)).rounded())
    }

    /// `850`, `12 mil`, `1,2 mi`.
    public static func formatTokens(_ tokens: Int) -> String {
        switch tokens {
        case ..<1000: return "\(tokens)"
        case ..<1_000_000: return "\(tokens / 1000) mil"
        default:
            let millions = Double(tokens) / 1_000_000
            return String(format: "%.1f mi", millions).replacingOccurrences(of: ".", with: ",")
        }
    }

    private static func startOfHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

/// Cota do Gemini (sempre estimada, calculada localmente).
public enum GeminiLimits {
    public static let defaultPromptsPerSession = 4.0

    /// Prompts do app web estimados: sessões web no dia de cota × taxa média por sessão.
    public static func estimatedWebPrompts(sessions: [Session], now: Date, promptsPerSession: Double) -> Int {
        let today = GeminiQuota.quotaDay(for: now)
        let web = sessions.filter {
            $0.provider == .gemini && !$0.source.hasPrefix("Gemini CLI") && GeminiQuota.quotaDay(for: $0.startedAt) == today
        }
        return Int((Double(web.count) * promptsPerSession).rounded())
    }

    public static func limits(now: Date, webPrompts: Int, quota: Int, cliRequests: Int) -> ProviderLimits {
        let reset = GeminiQuota.nextReset(after: now)
        let quota = max(1, quota)
        return ProviderLimits(provider: .gemini, source: .estimated, windows: [
            LimitWindow(
                id: "app_daily", label: "App · diária",
                usedPct: (Double(webPrompts) / Double(quota) * 100).rounded(),
                detail: "\(webPrompts) de \(quota) prompts",
                resetAt: reset, source: .estimated, updatedAt: now
            ),
            LimitWindow(
                id: "cli_daily", label: "CLI · diária",
                usedPct: (Double(cliRequests) / Double(GeminiQuota.cliRequests) * 100).rounded(),
                detail: "\(cliRequests) de \(GeminiQuota.cliRequests) req.",
                resetAt: reset, source: .estimated, updatedAt: now
            ),
        ])
    }
}

/// Alertas de 80% e 100%: no máximo um por janela, faixa e período de renovação.
public enum LimitAlerts {
    public struct Alert: Equatable, Sendable {
        public var key: String
        public var provider: ProviderID
        public var window: LimitWindow
        public var threshold: Int
    }

    public static let thresholds = [80, 100]

    /// Alertas a disparar agora e as chaves a marcar como enviadas (inclui faixas inferiores puladas).
    public static func due(_ limits: [ProviderLimits], alreadySent: Set<String>) -> (alerts: [Alert], keys: Set<String>) {
        var alerts: [Alert] = []
        var keys: Set<String> = []
        for provider in limits {
            for window in provider.windows {
                let period = window.resetAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "sem-renovacao"
                let crossed = thresholds.filter { window.usedPct >= Double($0) }
                guard let highest = crossed.max() else { continue }
                let key = { (t: Int) in "\(provider.provider.rawValue).\(window.id).\(t).\(period)" }
                if !alreadySent.contains(key(highest)) {
                    alerts.append(Alert(key: key(highest), provider: provider.provider, window: window, threshold: highest))
                }
                crossed.forEach { keys.insert(key($0)) }
            }
        }
        return (alerts, keys.subtracting(alreadySent))
    }
}
