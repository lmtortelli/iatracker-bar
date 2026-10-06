import AppKit
import ApplicationServices
import IAtrackerBarCore
import CoreServices

/// Estado das permissões de Acessibilidade e Automação (por navegador instalado).
@MainActor
final class PermissionsModel: ObservableObject {
    enum Status: Equatable {
        case granted, denied, notDetermined, notRunning, unknown

        var title: String {
            switch self {
            case .granted: "Permitido"
            case .denied: "Negado"
            case .notDetermined: "Não solicitado"
            case .notRunning: "Abra o navegador para verificar"
            case .unknown: "Desconhecido"
            }
        }
    }

    struct BrowserStatus: Identifiable, Equatable {
        let browser: Browser
        var status: Status
        var id: Browser { browser }
    }

    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var browsers: [BrowserStatus] = []

    var installedBrowsers: [Browser] {
        Browser.allCases.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        let installed = installedBrowsers
        Task.detached(priority: .utility) {
            let statuses = installed.map { BrowserStatus(browser: $0, status: Self.automationStatus($0, ask: false)) }
            await MainActor.run { self.browsers = statuses }
        }
    }

    /// Mostra o pedido de Automação do macOS (o navegador precisa estar aberto).
    func requestAutomation(_ browser: Browser) {
        Task.detached(priority: .userInitiated) {
            if Self.automationStatus(browser, ask: false) == .notRunning,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            _ = Self.automationStatus(browser, ask: true)
            await MainActor.run { self.refresh() }
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// `ask: true` bloqueia até o usuário responder: nunca chamar na main thread.
    nonisolated static func automationStatus(_ browser: Browser, ask: Bool) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: browser.bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch Int(status) {
        case Int(noErr): return .granted
        case -1743: return .denied
        case -1744: return .notDetermined
        case Int(procNotFound): return .notRunning
        default: return .unknown
        }
    }
}
