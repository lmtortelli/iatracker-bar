import AppKit
import IAtrackerBarCore
import SwiftUI

/// Lista de permissões usada nas boas-vindas e em Preferências › Permissões.
struct PermissionsList: View {
    @ObservedObject var model: PermissionsModel

    var body: some View {
        Section("Navegadores — Automação") {
            Text("Permite ler só o endereço da aba ativa, para saber se você está no claude.ai ou no Gemini.")
                .font(.caption)
                .foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.browsers.isEmpty {
                Text(model.installedBrowsers.isEmpty ? "Nenhum navegador compatível instalado (Safari, Chrome, Arc, Brave, Edge)." : "Verificando…")
                    .foregroundColor(Theme.secondary)
            }
            ForEach(model.browsers) { item in
                HStack {
                    StatusDot(color: Self.color(item.status))
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
                .accessibilityElement(children: .combine)
            }
        }

        Section("Acessibilidade — opcional") {
            HStack {
                StatusDot(color: model.accessibility ? Theme.statusActive : Theme.statusPaused)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Título da janela do app Claude")
                    Text("Usado só em regras de projeto por título. Sem ela, o app Claude é detectado normalmente.")
                        .font(.caption)
                        .foregroundColor(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !model.accessibility {
                    Button("Permitir") { model.requestAccessibility() }
                }
            }
        }
    }

    static func color(_ status: PermissionsModel.Status) -> Color {
        switch status {
        case .granted: Theme.statusActive
        case .denied: Theme.error
        case .notDetermined: Theme.warning
        case .notRunning, .unknown: Theme.statusPaused
        }
    }
}

// MARK: - Boas-vindas

/// Primeira execução, em passos: o que é, navegadores, Claude, ajustes, pronto.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, browsers, claude, settings, done
    }

    @EnvironmentObject private var state: AppState
    @StateObject private var permissions = PermissionsModel()
    @State private var step: Step
    let onFinish: () -> Void

    init(initialStep: Step = .welcome, onFinish: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.onFinish = onFinish
    }

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            HStack {
                progress
                Spacer()
                if step != .welcome {
                    Button("Voltar") { move(-1) }
                }
                if step == .done {
                    Button("Começar", action: onFinish).keyboardShortcut(.defaultAction)
                } else {
                    Button(step == .welcome ? "Configurar" : "Continuar") { move(1) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 540)
        .onAppear { permissions.refresh() }
        .onReceive(poll) { _ in if step == .browsers { permissions.refresh() } }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .browsers: browsers
        case .claude: claude
        case .settings: settings
        case .done: done
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Circle()
                    .fill(item == step ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel("Passo \(step.rawValue + 1) de \(Step.allCases.count)")
    }

    private func move(_ delta: Int) {
        step = Step(rawValue: step.rawValue + delta) ?? step
        if step == .claude, state.claudeConnection == .unknown { state.checkClaudeNow() }
    }

    // MARK: Passos

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bem-vindo ao IAtracker-bar").font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                Bullet(symbol: "clock", text: "Mede quanto tempo você usa Claude e Gemini — no navegador, no app Claude e no Claude Code.")
                Bullet(symbol: "folder", text: "Separa o tempo por projeto, pela pasta do git ou por regras suas.")
                Bullet(symbol: "gauge.with.dots.needle.33percent", text: "Mostra quanto resta dos limites do seu plano e avisa em 80% e 100%.")
                Bullet(symbol: "lock", text: "Só horários, origem e projeto ficam salvos, neste Mac. Nenhum conteúdo de conversa é lido ou enviado.")
            }
            Spacer(minLength: 0)
            MenuBarPreview(caption: "Ele mora na barra de menus, perto do relógio:")
        }
        .padding(24)
    }

    private var browsers: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Navegadores",
                text: "Para contar o uso no claude.ai e no Gemini, o app precisa ler o endereço da aba ativa. Clique em Permitir nos navegadores que você usa — o macOS vai confirmar. Pode pular e fazer depois."
            )
            Form { PermissionsList(model: permissions) }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Limites do Claude",
                text: "Com o login do Claude Code, o app mostra os limites oficiais da sua assinatura. Sem ele, mostra uma estimativa. Pode pular e fazer depois em Preferências › Operadores."
            )
            Form { Section { ClaudeConnectionView() } }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Ajustes rápidos", text: "Tudo isso pode ser mudado depois em Preferências.")
            Form {
                MenuBarMetricPicker()
                GeminiQuotaStepper()
                LaunchAtLoginToggle()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tudo pronto").font(.system(size: 22, weight: .semibold))
            Text("O IAtracker-bar já está registrando. Use o Claude ou o Gemini normalmente e clique no item da barra de menus para ver o uso de hoje, os limites e o relatório.")
                .fixedSize(horizontal: false, vertical: true)
            MenuBarPreview(caption: "Procure por isto na barra de menus:")
            Text("Dicas: ⌘, abre as Preferências com o popover aberto; ⌘Q encerra o app. Estas boas-vindas ficam em Preferências › Geral.")
                .font(.caption)
                .foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

private struct StepHeader: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(text)
                .foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }
}

private struct Bullet: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundColor(.accentColor)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Réplica do item da barra de menus, para a pessoa saber o que procurar.
private struct MenuBarPreview: View {
    @EnvironmentObject private var state: AppState
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption).font(.caption).foregroundColor(Theme.secondary)
            HStack(spacing: 6) {
                MenuBarLabel(state: state)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Janelas auxiliares (Preferências, boas-vindas) gerenciadas à mão: em app `LSUIElement`,
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
    static func showIfNeeded(state: AppState) {
        guard !UserDefaults.standard.bool(forKey: Preferences.Key.onboardingCompleted) else { return }
        show(state: state)
    }

    static func show(state: AppState) {
        AuxiliaryWindow.show(id: "onboarding", title: "IAtracker-bar") {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: Preferences.Key.onboardingCompleted)
                AuxiliaryWindow.close(id: "onboarding")
            }
            .environmentObject(state)
        }
    }
}
