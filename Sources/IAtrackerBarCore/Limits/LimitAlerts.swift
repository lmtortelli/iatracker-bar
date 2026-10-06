import Foundation

/// O que avisar e em quais janelas (Preferências › Avisos).
public struct AlertSettings: Equatable, Sendable {
    public static let allWindows: Set<String> = [ClaudeLimits.fiveHour, ClaudeLimits.sevenDay, "app_daily", "cli_daily"]

    /// Avisar ao passar de `nearThreshold`%.
    public var nearEnabled: Bool
    public var nearThreshold: Int
    /// Avisar ao atingir 100%.
    public var fullEnabled: Bool
    /// Avisar quando a janela renovar, se o pico de uso no período passou de `resetThreshold`%.
    public var resetEnabled: Bool
    public var resetThreshold: Int
    /// Ids das janelas observadas (`five_hour`, `seven_day`, `app_daily`, `cli_daily`).
    public var windows: Set<String>

    public init(
        nearEnabled: Bool = true,
        nearThreshold: Int = 80,
        fullEnabled: Bool = true,
        resetEnabled: Bool = true,
        resetThreshold: Int = 90,
        windows: Set<String> = AlertSettings.allWindows
    ) {
        self.nearEnabled = nearEnabled
        self.nearThreshold = nearThreshold
        self.fullEnabled = fullEnabled
        self.resetEnabled = resetEnabled
        self.resetThreshold = resetThreshold
        self.windows = windows
    }
}

/// Memória dos avisos entre execuções: o que já foi enviado e o pico de uso de cada período.
public struct AlertState: Codable, Equatable, Sendable {
    public struct Peak: Codable, Equatable, Sendable {
        public var provider: ProviderID
        public var window: String
        public var label: String
        public var resetAt: Date
        public var peak: Double
    }

    public var sent: [String] = []
    /// Chave do período (`claude.five_hour.<minuto da renovação>`) → pico observado.
    public var peaks: [String: Peak] = [:]

    public init() {}

    static let maxSent = 300

    mutating func markSent(_ key: String) {
        guard !sent.contains(key) else { return }
        sent.append(key)
        if sent.count > Self.maxSent { sent.removeFirst(sent.count - Self.maxSent) }
    }
}

public enum LimitAlerts {
    public enum Kind: Equatable, Sendable {
        case near(threshold: Int)
        case full
        case reset(peak: Int)
    }

    public struct Alert: Equatable, Sendable {
        public var key: String
        public var provider: ProviderID
        public var windowID: String
        public var kind: Kind
        public var title: String
        public var body: String
    }

    /// Decide os avisos a disparar agora e atualiza o estado (enviados + picos por período).
    /// - "Perto" e "100%" valem uma vez por janela e período de renovação; se as duas faixas
    ///   forem cruzadas de uma vez, só a mais alta é avisada.
    /// - "Renovou" é avisado depois do horário de renovação, se o pico do período passou do limite configurado.
    public static func evaluate(
        _ limits: [ProviderLimits],
        settings: AlertSettings,
        state: inout AlertState,
        now: Date
    ) -> [Alert] {
        var alerts: [Alert] = []
        let sent = Set(state.sent)

        for provider in limits {
            for window in provider.windows where settings.windows.contains(window.id) {
                guard let resetAt = window.resetAt, resetAt > now else { continue }
                let period = "\(provider.provider.rawValue).\(window.id).\(Int(resetAt.timeIntervalSince1970 / 60))"
                let name = "\(provider.provider.displayName) · \(window.label)"
                let renews = Formatters.reset(resetAt, now: now)

                // Pico do período, para o aviso de renovação.
                var peak = state.peaks[period] ?? AlertState.Peak(
                    provider: provider.provider, window: window.id, label: window.label, resetAt: resetAt, peak: 0
                )
                peak.peak = max(peak.peak, window.usedPct)
                state.peaks[period] = peak

                let fullKey = "\(period).full"
                let nearKey = "\(period).near\(settings.nearThreshold)"
                let isFull = settings.fullEnabled && window.usedPct >= 100
                let isNear = settings.nearEnabled && window.usedPct >= Double(settings.nearThreshold)

                if isFull {
                    if !sent.contains(fullKey) {
                        alerts.append(Alert(
                            key: fullKey, provider: provider.provider, windowID: window.id, kind: .full,
                            title: "\(name): limite atingido",
                            body: "\(renews.capitalizedFirst)."
                        ))
                    }
                    state.markSent(fullKey)
                    state.markSent(nearKey)
                } else if isNear {
                    if !sent.contains(nearKey) {
                        alerts.append(Alert(
                            key: nearKey, provider: provider.provider, windowID: window.id,
                            kind: .near(threshold: settings.nearThreshold),
                            title: "\(name) em \(Int(window.usedPct))%",
                            body: "Perto do limite. \(renews.capitalizedFirst)."
                        ))
                    }
                    state.markSent(nearKey)
                }
            }
        }

        // Renovações: períodos cujo horário já passou.
        for (period, peak) in state.peaks where peak.resetAt <= now {
            state.peaks[period] = nil
            let key = "\(period).reset"
            guard settings.resetEnabled,
                  settings.windows.contains(peak.window),
                  peak.peak >= Double(settings.resetThreshold),
                  !sent.contains(key),
                  now.timeIntervalSince(peak.resetAt) < 6 * 3600 // não avisa renovação muito antiga (app estava fechado)
            else { continue }
            alerts.append(Alert(
                key: key, provider: peak.provider, windowID: peak.window, kind: .reset(peak: Int(peak.peak)),
                title: "\(peak.provider.displayName) · \(peak.label) renovou",
                body: "O uso tinha chegado a \(Int(peak.peak))%. Já está liberado de novo."
            ))
            state.markSent(key)
        }

        return alerts.sorted { $0.key < $1.key }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
