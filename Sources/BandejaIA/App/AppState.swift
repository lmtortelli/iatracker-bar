import BandejaIACore
import Combine
import Foundation
import os

/// Estado de UI do app. Leituras e escritas no banco passam por aqui.
@MainActor
final class AppState: ObservableObject {
    enum Tab: Hashable {
        case today, report
    }

    @Published var tab: Tab = .today
    @Published var reportRange: ReportRange = .week

    @Published private(set) var paused = false
    /// Sessões que tocam o dia de hoje, mais antigas primeiro.
    @Published private(set) var todaySessions: [Session] = []
    @Published private(set) var projects: [Project] = []
    @Published private(set) var limits: [ProviderLimits] = []
    @Published private(set) var claudeConnection = ClaudeConnection.unknown
    /// Navegadores em que a Automação foi negada (aviso no popover).
    @Published private(set) var deniedBrowsers: Set<Browser> = []

    let database: AppDatabase
    let isDemo: Bool
    /// Coletores reais; `nil` no modo demonstração.
    private(set) var monitor: ActivityMonitor?
    private(set) var logWatcher: LogWatcher?
    private(set) var limitsService: LimitsService?
    /// Sessões do Claude abertas no último `reload` (para consultar limites quando uma termina).
    private var openClaudeSessions: Set<Int64> = []

    private let aggregator = ReportAggregator()
    private let logger = Logger(subsystem: "BandejaIA", category: "AppState")
    private var cancellables: Set<AnyCancellable> = []

    static let shared = bootstrap(demo: AppEnvironment.isDemo)

    init(database: AppDatabase, isDemo: Bool) {
        self.database = database
        self.isDemo = isDemo
        if !isDemo {
            paused = UserDefaults.standard.bool(forKey: Preferences.Key.paused)
        }
        reload()

        // Os limites mudam devagar; o cronômetro é atualizado pela própria view.
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshLimits() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLimits() }
            .store(in: &cancellables)
    }

    /// Inicia a coleta (fora do modo demonstração).
    func startCollecting() {
        guard !isDemo, monitor == nil else { return }
        let monitor = ActivityMonitor(database: database, paused: paused)
        monitor.onChange = { [weak self] in self?.reload() }
        monitor.onAutomationChange = { [weak self] denied in self?.deniedBrowsers = denied }
        monitor.start() // antes dos logs: fecha sessões órfãs da execução anterior
        self.monitor = monitor

        let logWatcher = LogWatcher(database: database, paused: paused)
        logWatcher.onChange = { [weak self] in self?.reload() }
        logWatcher.start()
        self.logWatcher = logWatcher

        let limitsService = LimitsService(database: database)
        limitsService.onUpdate = { [weak self] limits in self?.limits = limits }
        limitsService.onConnectionChange = { [weak self] connection in self?.claudeConnection = connection }
        self.limitsService = limitsService
        limitsService.start()
    }

    func checkClaudeNow() {
        limitsService?.checkClaudeNow()
    }

    /// Ao abrir o popover: dados frescos e, se permitido, nova consulta de limites.
    func popoverOpened() {
        reload()
        limitsService?.refresh(force: true)
    }

    static func bootstrap(demo isDemo: Bool) -> AppState {
        Preferences.registerDefaults()
        do {
            let database = isDemo ? try AppDatabase.inMemory() : try AppDatabase.onDisk()
            if isDemo { try DemoData.seed(database, now: .now) }
            return AppState(database: database, isDemo: isDemo)
        } catch {
            Logger(subsystem: "BandejaIA", category: "AppState")
                .error("Falha ao abrir o banco: \(error.localizedDescription, privacy: .public)")
            // Sem banco em disco o app segue funcionando em memória.
            guard let fallback = try? AppDatabase.inMemory() else {
                fatalError("SQLite indisponível até em memória")
            }
            return AppState(database: fallback, isDemo: isDemo)
        }
    }

    // MARK: Derivados

    var activeSession: Session? {
        todaySessions.last { $0.endedAt == nil }
    }

    func projectName(_ id: Int64?) -> String {
        guard let id, let project = projects.first(where: { $0.id == id }) else {
            return ReportAggregator.noProject
        }
        return project.name
    }

    func todaySummary(now: Date) -> TodaySummary {
        aggregator.today(todaySessions, now: now)
    }

    func report(now: Date) -> Report {
        let days = aggregator.days(for: reportRange, now: now)
        guard let first = days.first, let last = days.last,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last)
        else {
            return aggregator.report([], projects: [:], range: reportRange, now: now)
        }
        let sessions = (try? database.sessions(from: first, to: end)) ?? []
        let names = Dictionary(uniqueKeysWithValues: projects.compactMap { p in p.id.map { ($0, p.name) } })
        return aggregator.report(sessions, projects: names, range: reportRange, now: now)
    }

    /// Percentual da métrica escolhida para a barra de menus.
    func menuBarPercent(_ metric: MenuBarMetric) -> Double? {
        limits.first { $0.provider == metric.provider }?
            .windows.first { $0.id == metric.windowID }?
            .usedPct
    }

    // MARK: Ações

    func reload() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? .now
        do {
            todaySessions = try database.sessions(from: start, to: end)
            projects = try database.projects()
            let open = Set(todaySessions.filter { $0.endedAt == nil && $0.provider == .claude }.compactMap(\.id))
            if !openClaudeSessions.subtracting(open).isEmpty {
                limitsService?.refreshSoon(after: 10)
            }
            openClaudeSessions = open
        } catch {
            logger.error("Falha ao ler sessões: \(error.localizedDescription, privacy: .public)")
        }
        refreshLimits()
    }

    func refreshLimits() {
        guard isDemo else {
            limitsService?.publish()
            return
        }
        let now = Date.now
        let day = GeminiQuota.quotaDay(for: now)
        limits = DemoData.limits(
            now: now,
            activeStart: activeSession?.startedAt ?? DemoData.activeStart(now: now),
            geminiQuota: Preferences.geminiDailyQuota,
            webPrompts: (try? database.counter(.gemini, .webPrompts, day: day)) ?? 0,
            cliRequests: (try? database.counter(.gemini, .cliRequests, day: day)) ?? 0
        )
    }

    /// Escolha manual de projeto para a sessão ativa; sobrescreve a atribuição automática.
    func setActiveProject(_ project: Project) {
        guard var session = activeSession else { return }
        session.projectId = project.id
        session.manualProject = true
        save(session)
    }

    func togglePause() {
        paused.toggle()
        guard isDemo else {
            UserDefaults.standard.set(paused, forKey: Preferences.Key.paused)
            monitor?.setPaused(paused)
            logWatcher?.setPaused(paused)
            return
        }
        if paused, var session = activeSession {
            session.endedAt = .now
            save(session)
        } else if !paused, let last = todaySessions.last {
            // No modo demonstração não há coletor: retoma uma sessão igual à última.
            insert(Session(
                provider: last.provider,
                source: last.source,
                projectId: last.projectId,
                cwd: last.cwd,
                startedAt: .now,
                manualProject: last.manualProject
            ))
        }
    }

    /// Cria o projeto (ou reaproveita um de mesmo nome) e atribui à sessão ativa.
    func createProjectForActiveSession(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let project = try database.project(named: trimmed)
            reload()
            setActiveProject(project)
        } catch {
            logger.error("Falha ao criar projeto: \(error.localizedDescription, privacy: .public)")
        }
    }

    func renameProject(id: Int64, to name: String) {
        perform { try $0.renameProject(id: id, to: name) }
    }

    func deleteProject(id: Int64) {
        perform { try $0.deleteProject(id: id) }
    }

    func addProject(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform { try $0.project(named: trimmed) }
    }

    // MARK: Persistência

    private func save(_ session: Session) {
        perform { try $0.update(session) }
    }

    private func insert(_ session: Session) {
        perform { try $0.insert(session) }
    }

    private func perform(_ work: (AppDatabase) throws -> Void) {
        do {
            try work(database)
        } catch {
            logger.error("Falha ao gravar: \(error.localizedDescription, privacy: .public)")
        }
        reload()
    }
}

enum AppEnvironment {
    /// `--demo` (ou `BANDEJA_DEMO=1`) abre um banco em memória com os dados do protótipo.
    static var isDemo: Bool {
        CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["BANDEJA_DEMO"] == "1"
    }
}
