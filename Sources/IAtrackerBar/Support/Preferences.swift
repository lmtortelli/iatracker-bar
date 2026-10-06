import IAtrackerBarCore
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

/// Chaves e valores padrão do `UserDefaults`.
enum Preferences {
    enum Key {
        static let menuBarMetric = "menuBarMetric"
        static let geminiDailyQuota = "geminiDailyQuota"
        static let idleMinutes = "idleMinutes"
        static let paused = "paused"
        static let claudeTokenBudget = "claudeTokenBudget"
        static let geminiPromptsPerSession = "geminiPromptsPerSession"
        static let alertNearEnabled = "alertNearEnabled"
        static let alertNearThreshold = "alertNearThreshold"
        static let alertFullEnabled = "alertFullEnabled"
        static let alertResetEnabled = "alertResetEnabled"
        static let alertResetThreshold = "alertResetThreshold"
        static let alertWindows = "alertWindows"
        static let onboardingCompleted = "onboardingCompleted"
    }

    /// O projeto se chamava "Bandeja IA" (bundle `io.github.bandejaia`): copia as preferências antigas uma vez.
    static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "legacyDefaultsMigrated"),
              let legacy = UserDefaults(suiteName: "io.github.bandejaia")
        else { return }
        let keys = [
            Key.menuBarMetric, Key.geminiDailyQuota, Key.idleMinutes, Key.paused,
            Key.onboardingCompleted, Key.claudeTokenBudget, Key.geminiPromptsPerSession,
            "lastHeartbeat",
        ]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "legacyDefaultsMigrated")
    }

    static func registerDefaults() {
        migrateLegacyDefaults()
        UserDefaults.standard.register(defaults: [
            Key.menuBarMetric: MenuBarMetric.claude5h.rawValue,
            Key.geminiDailyQuota: GeminiQuota.defaultAppPrompts,
            Key.idleMinutes: 2,
            Key.geminiPromptsPerSession: GeminiLimits.defaultPromptsPerSession,
            Key.alertNearEnabled: true,
            Key.alertNearThreshold: 80,
            Key.alertFullEnabled: true,
            Key.alertResetEnabled: true,
            Key.alertResetThreshold: 90,
            Key.alertWindows: Array(AlertSettings.allWindows).sorted(),
        ])
    }

    static var geminiDailyQuota: Int {
        UserDefaults.standard.integer(forKey: Key.geminiDailyQuota)
    }

    static var alertSettings: AlertSettings {
        let defaults = UserDefaults.standard
        return AlertSettings(
            nearEnabled: defaults.bool(forKey: Key.alertNearEnabled),
            nearThreshold: defaults.integer(forKey: Key.alertNearThreshold),
            fullEnabled: defaults.bool(forKey: Key.alertFullEnabled),
            resetEnabled: defaults.bool(forKey: Key.alertResetEnabled),
            resetThreshold: defaults.integer(forKey: Key.alertResetThreshold),
            windows: Set(defaults.stringArray(forKey: Key.alertWindows) ?? Array(AlertSettings.allWindows))
        )
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
