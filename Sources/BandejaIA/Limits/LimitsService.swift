import BandejaIACore
import Foundation
import os
import UserNotifications

/// Monta os limites exibidos: Claude oficial (com último snapshot válido e estimativa como plano B)
/// e Gemini estimado localmente. Consulta remota a cada 3 min, ao abrir o popover e 10 s após o fim
/// de uma sessão do Claude; em erro, backoff exponencial até 30 min.
@MainActor
final class LimitsService {
    static let refreshInterval: TimeInterval = 3 * 60
    static let maxBackoff: TimeInterval = 30 * 60
    /// Intervalo mínimo entre consultas disparadas por abrir o popover.
    static let minInterval: TimeInterval = 30

    private enum ClaudeState: Equatable {
        case unknown, official, noCredential, failed
    }

    var onUpdate: ([ProviderLimits]) -> Void = { _ in }

    private let database: AppDatabase
    private let claude = ClaudeProvider()
    private let notifier = LimitNotifier()
    private let logger = Logger(subsystem: "BandejaIA", category: "LimitsService")
    private var claudeState = ClaudeState.unknown
    private var backoff: TimeInterval = 0
    private var nextAllowedFetch = Date.distantPast
    private var fetching = false
    private var timer: Timer?

    init(database: AppDatabase) {
        self.database = database
    }

    func start() {
        publish()
        refresh(force: true)
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Consulta o operador se o backoff permitir (`force` ignora o intervalo mínimo, não o backoff de erro).
    func refresh(force: Bool = false) {
        let now = Date()
        guard !fetching, now >= nextAllowedFetch || (force && backoff == 0) else {
            publish()
            return
        }
        fetching = true
        let provider = claude
        Task {
            let result: Result<[LimitSnapshot], Error>
            do {
                // Leitura do Keychain pode bloquear com o pedido de permissão: fora da main thread.
                result = .success(try await Task.detached { try await provider.fetchLimits(now: now) }.value)
            } catch {
                result = .failure(error)
            }
            handle(result, now: now)
            fetching = false
            publish()
        }
    }

    func refreshSoon(after seconds: TimeInterval = 10) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
    }

    private func handle(_ result: Result<[LimitSnapshot], Error>, now: Date) {
        switch result {
        case let .success(snapshots):
            do {
                try database.save(snapshots, pruneBefore: now.addingTimeInterval(-7 * 24 * 3600))
            } catch {
                logger.error("Falha ao gravar limites: \(error.localizedDescription, privacy: .public)")
            }
            calibrate(with: snapshots, now: now)
            claudeState = .official
            backoff = 0
            nextAllowedFetch = now.addingTimeInterval(Self.minInterval)
        case let .failure(error):
            if (error as? ClaudeProvider.Failure) == .noCredential {
                claudeState = .noCredential
                backoff = 0
                nextAllowedFetch = now.addingTimeInterval(Self.refreshInterval)
            } else {
                claudeState = .failed
                backoff = min(max(60, backoff * 2), Self.maxBackoff)
                nextAllowedFetch = now.addingTimeInterval(backoff)
                logger.info("Consulta de limites falhou: \(String(describing: error), privacy: .public); próxima em \(Int(self.backoff)) s")
            }
        }
    }

    /// Ajusta o orçamento da estimativa com o dado oficial (tokens locais ÷ uso da janela de 5 h).
    private func calibrate(with snapshots: [LimitSnapshot], now: Date) {
        guard let fiveHour = snapshots.first(where: { $0.window == ClaudeLimits.fiveHour }) else { return }
        let tokens = claudeTokensInWindow(now: now).values.reduce(0, +)
        if let budget = ClaudeEstimator.calibratedBudget(tokens: tokens, utilization: fiveHour.usedPct) {
            UserDefaults.standard.set(budget, forKey: Preferences.Key.claudeTokenBudget)
        }
    }

    // MARK: Montagem

    /// Recalcula e publica sem rede (Gemini, estimativa, dado velho).
    func publish() {
        let now = Date()
        let limits = [claudeLimits(now: now), geminiLimits(now: now)]
        onUpdate(limits)

        // Estimativa sem calibração usa um orçamento arbitrário: não gera alerta.
        let alertable = limits.filter { $0.source == .official || $0.provider != .claude || Preferences.claudeBudgetIsCalibrated }
        notifier.check(alertable)
    }

    /// Último dado oficial ainda útil: até 6 h depois da consulta (depois disso, a estimativa diz mais).
    static let snapshotShelfLife: TimeInterval = 6 * 3600

    private func claudeLimits(now: Date) -> ProviderLimits {
        let snapshots = ((try? database.latestSnapshots(for: .claude)) ?? [])
            .filter { now.timeIntervalSince($0.fetchedAt) < Self.snapshotShelfLife }

        switch claudeState {
        case .official, .unknown:
            if !snapshots.isEmpty { return ClaudeLimits.limits(from: snapshots, now: now) }
            return estimate(now: now, note: nil)
        case .failed:
            if !snapshots.isEmpty {
                return ClaudeLimits.limits(from: snapshots, now: now, note: "Consulta falhou; mostrando o último dado.")
            }
            return estimate(now: now, note: "Consulta falhou: estimado pelos tokens do Claude Code.")
        case .noCredential:
            if !snapshots.isEmpty {
                return ClaudeLimits.limits(from: snapshots, now: now, note: "Credencial indisponível; mostrando o último dado.")
            }
            return estimate(now: now, note: "Sem credencial: estimado pelos tokens do Claude Code. Configure em Preferências › Operadores.")
        }
    }

    private func estimate(now: Date, note: String?) -> ProviderLimits {
        ClaudeEstimator.estimate(
            tokensByHour: claudeTokensInWindow(now: now),
            budget: Preferences.claudeTokenBudget,
            now: now,
            note: note
        )
    }

    private func claudeTokensInWindow(now: Date) -> [String: Int] {
        (try? database.counters(.claude, .claudeCodeTokens, days: ClaudeEstimator.hourKeys(now: now))) ?? [:]
    }

    private func geminiLimits(now: Date) -> ProviderLimits {
        let day = GeminiQuota.quotaDay(for: now)
        let recent = (try? database.sessions(from: now.addingTimeInterval(-2 * 24 * 3600), to: now.addingTimeInterval(3600))) ?? []
        return GeminiLimits.limits(
            now: now,
            webPrompts: GeminiLimits.estimatedWebPrompts(
                sessions: recent,
                now: now,
                promptsPerSession: Preferences.geminiPromptsPerSession
            ) + ((try? database.counter(.gemini, .webPrompts, day: day)) ?? 0),
            quota: Preferences.geminiDailyQuota,
            cliRequests: (try? database.counter(.gemini, .cliRequests, day: day)) ?? 0
        )
    }
}

/// Notificações locais ao cruzar 80% e 100% (uma vez por janela e período).
@MainActor
final class LimitNotifier {
    private static let sentKey = "sentLimitAlerts"

    func check(_ limits: [ProviderLimits]) {
        let defaults = UserDefaults.standard
        let sent = Set(defaults.stringArray(forKey: Self.sentKey) ?? [])
        let (alerts, keys) = LimitAlerts.due(limits, alreadySent: sent)
        guard !keys.isEmpty else { return }
        defaults.set(Array((Array(sent) + keys).suffix(300)), forKey: Self.sentKey)

        // UNUserNotificationCenter exige um bundle (.app); em `swift run` só registra.
        guard !alerts.isEmpty, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for alert in alerts {
                let content = UNMutableNotificationContent()
                content.title = "\(alert.provider.displayName) · \(alert.window.label): \(Int(alert.window.usedPct))%"
                let reset = Formatters.reset(alert.window.resetAt, now: Date())
                content.body = alert.threshold >= 100 ? "Limite atingido. \(reset.capitalizedFirst)." : "\(reset.capitalizedFirst)."
                content.sound = .default
                center.add(UNNotificationRequest(identifier: alert.key, content: content, trigger: nil))
            }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
