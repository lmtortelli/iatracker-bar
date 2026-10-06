import AppKit
import IAtrackerBarCore
import ServiceManagement
import SwiftUI

@MainActor
enum PreferencesWindow {
    static func show(state: AppState) {
        AuxiliaryWindow.show(id: "preferences", title: "Preferências do IAtracker-bar") {
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
        .frame(width: 540, height: 480)
    }
}

// MARK: - Geral

private struct GeneralPane: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(Preferences.Key.idleMinutes) private var idleMinutes = 2

    var body: some View {
        Form {
            MenuBarMetricPicker()
            LaunchAtLoginToggle()
            Stepper(value: $idleMinutes, in: 1...30) {
                Text("Encerrar sessão após \(idleMinutes) min sem teclado ou mouse")
            }

            Section {
                Button("Mostrar as boas-vindas novamente") { OnboardingWindow.show(state: state) }
                Button("Sair do IAtracker-bar") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }
}

struct MenuBarMetricPicker: View {
    @AppStorage(Preferences.Key.menuBarMetric) private var metric = MenuBarMetric.claude5h.rawValue

    var body: some View {
        Picker("Métrica na barra de menus", selection: $metric) {
            ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0.rawValue) }
        }
    }
}

struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Toggle("Abrir o IAtracker-bar ao iniciar o Mac", isOn: $enabled)
            .onChange(of: enabled, perform: apply)
        if let error {
            Text(error).font(.caption).foregroundColor(Theme.error)
        }
    }

    private func apply(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Não foi possível alterar. Mova o IAtracker-bar para a pasta Aplicativos e tente de novo."
        }
    }
}

// MARK: - Operadores

private struct ProvidersPane: View {
    @AppStorage(Preferences.Key.geminiPromptsPerSession) private var promptsPerSession = GeminiLimits.defaultPromptsPerSession

    var body: some View {
        Form {
            Section("Claude") {
                ClaudeConnectionView()
                Text("Sem a conexão, a janela de 5 h é estimada pelos tokens do Claude Code (orçamento de \(ClaudeEstimator.formatTokens(Preferences.claudeTokenBudget)) tokens, \(Preferences.claudeBudgetIsCalibrated ? "calibrado com o dado oficial" : "valor padrão, ainda sem calibração")). Os limites usam um endpoint não documentado e podem parar de funcionar sem aviso.")
                    .font(.caption)
                    .foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Gemini") {
                GeminiQuotaStepper()
                Stepper(value: $promptsPerSession, in: 1...20, step: 1) {
                    Text("Prompts estimados por sessão no app: \(Int(promptsPerSession))")
                }
                Text("O Gemini não informa o uso restante: a contagem é feita aqui e zera à meia-noite do Pacífico. Gemini CLI: \(GeminiQuota.cliRequests) requisições por dia.")
                    .font(.caption)
                    .foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

struct GeminiQuotaStepper: View {
    @AppStorage(Preferences.Key.geminiDailyQuota) private var geminiQuota = GeminiQuota.defaultAppPrompts

    var body: some View {
        Stepper(value: $geminiQuota, in: 10...1000, step: 10) {
            Text("Cota diária do app Gemini: \(geminiQuota) prompts")
        }
    }
}

/// Status da conexão com os limites oficiais do Claude, com o passo a passo para conectar.
struct ClaudeConnectionView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(color: dotColor)
                Text(title).fontWeight(.medium)
                Spacer()
                if state.claudeConnection == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Verificar agora") { state.checkClaudeNow() }
                }
            }

            switch state.claudeConnection {
            case let .connected(date):
                Text("Limites oficiais da sua assinatura (sessão de 5 h e semanal). Última consulta: \(Formatters.time(date)).")
                    .font(.caption)
                    .foregroundColor(Theme.secondary)
            case .checking:
                Text("Se o macOS perguntar sobre “Claude Code-credentials”, escolha Sempre permitir.")
                    .font(.caption)
                    .foregroundColor(Theme.secondary)
            default:
                instructions
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Para ver os limites oficiais, o IAtracker-bar usa o login do Claude Code. Faça uma vez:")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            StepLine(number: 1, text: "Instale o Claude Code, se ainda não tiver:")
            CommandRow(command: "curl -fsSL https://claude.ai/install.sh | bash")
            StepLine(number: 2, text: "Abra o Claude Code, digite /login e conclua no navegador:")
            CommandRow(command: "~/.local/bin/claude")
            StepLine(number: 3, text: "Volte aqui, clique em Verificar agora e, quando o macOS perguntar, escolha Sempre permitir.")
        }
    }

    private var title: String {
        switch state.claudeConnection {
        case .connected: "Conectado"
        case .checking: "Verificando…"
        case .notLoggedIn: "Sem login no Claude Code"
        case .failed: "A consulta falhou; o app tenta de novo sozinho"
        case .unknown: "Ainda não verificado"
        }
    }

    private var dotColor: Color {
        switch state.claudeConnection {
        case .connected: Theme.statusActive
        case .checking, .unknown: Theme.statusPaused
        case .notLoggedIn: Theme.warning
        case .failed: Theme.error
        }
    }
}

private struct StepLine: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").font(Theme.mono(11, .semibold))
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Comando para copiar e colar no Terminal.
struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(Theme.mono(11))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            Button(copied ? "Copiado" : "Copiar") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            Button("Abrir Terminal") {
                if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    NSWorkspace.shared.openApplication(at: terminal, configuration: .init())
                }
            }
        }
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
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
                if state.projects.isEmpty {
                    Text("Nenhum projeto ainda. Eles são criados sozinhos pela pasta do git quando você usa o Claude Code, ou à mão aqui e no menu Projeto ▾ do popover.")
                        .foregroundColor(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(state.projects) { project in
                    HStack {
                        Text(project.name)
                        Spacer()
                        Button("Renomear") { rename(project) }.buttonStyle(.borderless)
                        Button("Excluir") { delete(project) }.buttonStyle(.borderless).foregroundColor(Theme.error)
                    }
                }
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
                    Text("Sem regras, a pasta do repositório git vira o projeto e o uso no navegador vai para o último projeto usado.")
                        .foregroundColor(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        case .domain: "claude.ai/project/…"
        case .title: "trecho do título da aba ou da janela"
        }
    }

    private func kindTitle(_ kind: ProjectRule.Kind) -> String {
        switch kind {
        case .cwd: "Pasta"
        case .domain: "Endereço"
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

    private func rename(_ project: Project) {
        guard let id = project.id,
              let name = TextPrompt.ask(
                  title: "Renomear projeto",
                  message: "Se já existir um projeto com o novo nome, os dois são juntados.",
                  initial: project.name
              )
        else { return }
        state.renameProject(id: id, to: name)
        loadRules()
    }

    private func delete(_ project: Project) {
        guard let id = project.id else { return }
        let alert = NSAlert()
        alert.messageText = "Excluir “\(project.name)”?"
        alert.informativeText = "As sessões continuam registradas, mas ficam sem projeto. As regras deste projeto são removidas."
        alert.addButton(withTitle: "Excluir")
        alert.addButton(withTitle: "Cancelar")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.deleteProject(id: id)
        loadRules()
    }
}

/// Pergunta curta com campo de texto (modal).
@MainActor
enum TextPrompt {
    static func ask(title: String, message: String, initial: String = "", confirm: String = "OK") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Nome do projeto"
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Permissões

private struct PermissionsPane: View {
    @StateObject private var model = PermissionsModel()

    var body: some View {
        Form {
            PermissionsList(model: model)
            Section {
                Text("O IAtracker-bar registra só horários, origem e projeto. Nenhum conteúdo de conversa é lido ou salvo.")
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
