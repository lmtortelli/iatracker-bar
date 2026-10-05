import AppKit
import BandejaIACore
import SwiftUI

/// Lista de permissões usada no onboarding e em Preferências › Permissões.
struct PermissionsList: View {
    @ObservedObject var model: PermissionsModel

    var body: some View {
        Section("Automação — necessária") {
            Text("Permite ler só a URL da aba ativa para saber se você está no claude.ai ou no Gemini.")
                .font(.caption)
                .foregroundColor(Theme.secondary)
            if model.browsers.isEmpty {
                Text(model.installedBrowsers.isEmpty ? "Nenhum navegador compatível instalado." : "Verificando…")
                    .foregroundColor(Theme.secondary)
            }
            ForEach(model.browsers) { item in
                HStack {
                    StatusDot(status: item.status)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.browser.displayName)
                        Text(item.status.title).font(.caption).foregroundColor(Theme.secondary)
                    }
                    Spacer()
                    switch item.status {
                    case .granted:
                        EmptyView()
                    case .denied:
                        Button("Abrir Ajustes") { PermissionsModel.openSettings("Privacy_Automation") }
                    default:
                        Button("Permitir") { model.requestAutomation(item.browser) }
                    }
                }
            }
        }

        Section("Acessibilidade — opcional") {
            HStack {
                StatusDot(status: model.accessibility ? .granted : .notDetermined)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Título da janela do app Claude")
                    Text("Usado só para regras de projeto por título. Sem ela, o app Claude é detectado normalmente.")
                        .font(.caption)
                        .foregroundColor(Theme.secondary)
                }
                Spacer()
                if !model.accessibility {
                    Button("Permitir") { model.requestAccessibility() }
                }
            }
        }
    }
}

private struct StatusDot: View {
    let status: PermissionsModel.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(status.title)
    }

    private var color: Color {
        switch status {
        case .granted: Theme.statusActive
        case .denied: Theme.error
        case .notDetermined: Theme.warning
        case .notRunning, .unknown: Theme.statusPaused
        }
    }
}

/// Primeira execução: explica o que é coletado e pede as permissões.
struct OnboardingView: View {
    @StateObject private var model = PermissionsModel()
    let onFinish: () -> Void

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bem-vindo ao Bandeja IA").font(.system(size: 20, weight: .semibold))
                Text("O app mede quanto tempo você usa Claude e Gemini e em qual projeto. Ele registra só horários, origem e projeto — nenhum conteúdo de conversa é lido ou salvo.")
                    .foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Form {
                PermissionsList(model: model)
            }
            .formStyle(.grouped)

            HStack {
                Text("Você pode mudar isso depois em Preferências › Permissões.")
                    .font(.caption)
                    .foregroundColor(Theme.secondary)
                Spacer()
                Button("Concluir", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 520)
        .onAppear { model.refresh() }
        .onReceive(poll) { _ in model.refresh() }
    }
}

/// Janelas auxiliares (Preferências, onboarding) gerenciadas à mão: em app `LSUIElement`,
/// a cena `Settings` abre atrás das outras janelas e `showSettingsWindow:` não funciona no macOS 14+.
@MainActor
enum AuxiliaryWindow {
    private static var windows: [String: NSWindow] = [:]

    static func show<Content: View>(id: String, title: String, content: () -> Content) {
        if windows[id] == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            windows[id] = window
        }
        NSApp.activate(ignoringOtherApps: true)
        windows[id]?.makeKeyAndOrderFront(nil)
    }

    static func close(id: String) {
        windows[id]?.close()
    }
}

@MainActor
enum OnboardingWindow {
    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Preferences.Key.onboardingCompleted) else { return }
        AuxiliaryWindow.show(id: "onboarding", title: "Bandeja IA") {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: Preferences.Key.onboardingCompleted)
                AuxiliaryWindow.close(id: "onboarding")
            }
        }
    }
}
