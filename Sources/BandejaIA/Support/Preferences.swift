import BandejaIACore
import Foundation

/// Métrica exibida no item da barra de menus.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case claude5h
    case claudeWeekly
    case gemini

    var id: String { rawValue }

    /// Texto curto na barra.
    var label: String {
        switch self {
        case .claude5h: "Claude 5h"
        case .claudeWeekly: "Claude sem."
        case .gemini: "Gemini"
        }
    }

    /// Texto no seletor das Preferências.
    var title: String {
        switch self {
        case .claude5h: "Claude · sessão de 5 h"
        case .claudeWeekly: "Claude · semanal"
        case .gemini: "Gemini · app diária"
        }
    }

    var provider: ProviderID {
        self == .gemini ? .gemini : .claude
    }

    var windowID: String {
        switch self {
        case .claude5h: "five_hour"
        case .claudeWeekly: "seven_day"
        case .gemini: "app_daily"
        }
    }
}

enum ClaudeCredentialSource: String, CaseIterable, Identifiable {
    case claudeCode
    case sessionKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Token do Claude Code (Keychain)"
        case .sessionKey: "sessionKey do claude.ai"
        }
    }
}

/// Chaves e valores padrão do `UserDefaults`.
enum Preferences {
    enum Key {
        static let menuBarMetric = "menuBarMetric"
        static let geminiDailyQuota = "geminiDailyQuota"
        static let idleMinutes = "idleMinutes"
        static let claudeCredentialSource = "claudeCredentialSource"
        static let paused = "paused"
        static let claudeTokenBudget = "claudeTokenBudget"
        static let geminiPromptsPerSession = "geminiPromptsPerSession"
        static let onboardingCompleted = "onboardingCompleted"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.menuBarMetric: MenuBarMetric.claude5h.rawValue,
            Key.geminiDailyQuota: GeminiQuota.defaultAppPrompts,
            Key.idleMinutes: 2,
            Key.claudeCredentialSource: ClaudeCredentialSource.claudeCode.rawValue,
            Key.geminiPromptsPerSession: GeminiLimits.defaultPromptsPerSession,
        ])
    }

    static var geminiDailyQuota: Int {
        UserDefaults.standard.integer(forKey: Key.geminiDailyQuota)
    }

    static var geminiPromptsPerSession: Double {
        UserDefaults.standard.double(forKey: Key.geminiPromptsPerSession)
    }

    /// Orçamento da estimativa de 5 h: calibrado com dado oficial ou o padrão.
    static var claudeTokenBudget: Int {
        let calibrated = UserDefaults.standard.integer(forKey: Key.claudeTokenBudget)
        return calibrated > 0 ? calibrated : ClaudeEstimator.defaultBudget
    }

    static var claudeBudgetIsCalibrated: Bool {
        UserDefaults.standard.integer(forKey: Key.claudeTokenBudget) > 0
    }

    static var idleSeconds: TimeInterval {
        TimeInterval(max(1, UserDefaults.standard.integer(forKey: Key.idleMinutes)) * 60)
    }
}
