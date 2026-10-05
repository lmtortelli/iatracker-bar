import AppKit
import BandejaIACore
import ServiceManagement
import SwiftUI

@MainActor
enum PreferencesWindow {
    static func show(state: AppState) {
        AuxiliaryWindow.show(id: "preferences", title: "Preferências do Bandeja IA") {
            PreferencesView().environmentObject(state)
        }
    }
}

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("Geral", systemImage: "gearshape") }
            ProvidersPane().tabItem { Label("Operadores", systemImage: "sparkles") }
            ProjectsPane().tabItem { Label("Projetos", systemImage: "folder") }
            PermissionsPane().tabItem { Label("Permissões", systemImage: "lock.shield") }
        }
        .padding(12)
        .frame(width: 520, height: 440)
    }
}

// MARK: - Geral

private struct GeneralPane: View {
    @AppStorage(Preferences.Key.menuBarMetric) private var metric = MenuBarMetric.claude5h.rawValue
    @AppStorage(Preferences.Key.idleMinutes) private var idleMinutes = 2
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Picker("Métrica na barra de menus", selection: $metric) {
                ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0.rawValue) }
            }

            Toggle("Iniciar com o sistema", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin, perform: setLaunchAtLogin)
            if let launchError {
                Text(launchError).font(.caption).foregroundColor(Theme.error)
            }

            Stepper(value: $idleMinutes, in: 1...30) {
                Text("Encerrar sessão após \(idleMinutes) min sem atividade")
            }

            Section {
                Button("Sair do Bandeja IA") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "Não foi possível alterar: \(error.localizedDescription). Rode o app a partir do .app em /Applications."
        }
    }
}

// MARK: - Operadores

private struct ProvidersPane: View {
    @AppStorage(Preferences.Key.claudeCredentialSource) private var credentialSource = ClaudeCredentialSource.claudeCode.rawValue
    @AppStorage(Preferences.Key.geminiDailyQuota) private var geminiQuota = GeminiQuota.defaultAppPrompts
    @State private var sessionKey = ""
    @State private var hasSessionKey = Keychain.exists(account: Keychain.Account.claudeSessionKey)
    @State private var keychainError: String?

    var body: some View {
        Form {
            Section("Claude") {
                Picker("Origem da credencial", selection: $credentialSource) {
                    ForEach(ClaudeCredentialSource.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if credentialSource == ClaudeCredentialSource.sessionKey.rawValue {
                    SecureField("sessionKey", text: $sessionKey, prompt: Text(hasSessionKey ? "•••••• salvo no Keychain" : "cole o cookie sessionKey"))
                    HStack {
                        Button("Salvar no Keychain", action: saveSessionKey)
                            .disabled(sessionKey.isEmpty)
                        if hasSessionKey {
                            Button("Remover", role: .destructive) {
                                Keychain.delete(account: Keychain.Account.claudeSessionKey)
                                hasSessionKey = false
                            }
                        }
                    }
                    if let keychainError {
                        Text(keychainError).font(.caption).foregroundColor(Theme.error)
                    }
                } else {
                    Text("Lê o token OAuth que o Claude Code guarda no Keychain (item “Claude Code-credentials”). O macOS pedirá permissão na primeira leitura.")
                        .font(.caption)
                        .foregroundColor(Theme.secondary)
                }
                Text("Os limites do Claude usam um endpoint não documentado e podem parar de funcionar sem aviso.")
                    .font(.caption)
                    .foregroundColor(Theme.secondary)
            }

            Section("Gemini") {
                Stepper(value: $geminiQuota, in: 10...1000, step: 10) {
                    Text("Cota diária do app: \(geminiQuota) prompts")
                }
                Text("O Gemini não expõe uso restante; a contagem é local e zera à meia-noite do Pacífico. CLI: \(GeminiQuota.cliRequests) requisições/dia.")
                    .font(.caption)
                    .foregroundColor(Theme.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func saveSessionKey() {
        do {
            try Keychain.save(sessionKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Keychain.Account.claudeSessionKey)
            sessionKey = ""
            hasSessionKey = true
            keychainError = nil
        } catch {
            keychainError = "Falha ao salvar no Keychain."
        }
    }
}

// MARK: - Projetos

private struct ProjectsPane: View {
    @EnvironmentObject private var state: AppState
    @State private var rules: [ProjectRule] = []
    @State private var newProject = ""
    @State private var ruleProjectID: Int64?
    @State private var ruleKind: ProjectRule.Kind = .cwd
    @State private var rulePattern = ""

    var body: some View {
        Form {
            Section("Projetos") {
                HStack {
                    TextField("Novo projeto", text: $newProject)
                    Button("Adicionar") {
                        state.addProject(named: newProject)
                        newProject = ""
                    }
                    .disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Regras de atribuição") {
                if rules.isEmpty {
                    Text("Nenhuma regra. Sem regra, o nome da pasta do git vira o projeto.")
                        .foregroundColor(Theme.secondary)
                }
                ForEach(rules) { rule in
                    HStack {
                        Text(kindTitle(rule.kind)).foregroundColor(Theme.secondary).frame(width: 70, alignment: .leading)
                        Text(rule.pattern).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("→ \(state.projectName(rule.projectId))")
                        Button {
                            if let id = rule.id { try? state.database.deleteRule(id: id) }
                            loadRules()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remover regra")
                    }
                }
            }

            Section("Nova regra") {
                Picker("Tipo", selection: $ruleKind) {
                    ForEach(ProjectRule.Kind.allCases, id: \.self) { Text(kindTitle($0)).tag($0) }
                }
                TextField(placeholder, text: $rulePattern)
                Picker("Projeto", selection: $ruleProjectID) {
                    Text("Escolha…").tag(Int64?.none)
                    ForEach(state.projects) { Text($0.name).tag($0.id) }
                }
                Button("Adicionar regra", action: addRule)
                    .disabled(ruleProjectID == nil || rulePattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadRules)
    }

    private var placeholder: String {
        switch ruleKind {
        case .cwd: "~/dev/meu-projeto"
        case .domain: "gemini.google.com"
        case .title: "trecho do título da aba"
        }
    }

    private func kindTitle(_ kind: ProjectRule.Kind) -> String {
        switch kind {
        case .cwd: "Pasta"
        case .domain: "Domínio"
        case .title: "Título"
        }
    }

    private func loadRules() {
        rules = (try? state.database.rules()) ?? []
    }

    private func addRule() {
        guard let ruleProjectID else { return }
        _ = try? state.database.insert(ProjectRule(
            projectId: ruleProjectID,
            kind: ruleKind,
            pattern: rulePattern.trimmingCharacters(in: .whitespaces)
        ))
        rulePattern = ""
        loadRules()
    }
}

// MARK: - Permissões

private struct PermissionsPane: View {
    @StateObject private var model = PermissionsModel()

    var body: some View {
        Form {
            PermissionsList(model: model)
            Section {
                Text("O Bandeja IA registra só horários, origem e projeto. Nenhum conteúdo de conversa é lido ou salvo.")
                    .font(.caption)
                    .foregroundColor(Theme.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
