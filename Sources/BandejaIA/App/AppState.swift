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

    let database: AppDatabase
    let isDemo: Bool

    private let aggregator = ReportAggregator()
    private let logger = Logger(subsystem: "BandejaIA", category: "AppState")
    private var cancellables: Set<AnyCancellable> = []

    init(database: AppDatabase, isDemo: Bool) {
        self.database = database
        self.isDemo = isDemo
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

    static func bootstrap() -> AppState {
        Preferences.registerDefaults()
        let isDemo = AppEnvironment.isDemo
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
        } catch {
            logger.error("Falha ao ler sessões: \(error.localizedDescription, privacy: .public)")
        }
        refreshLimits()
    }

    func refreshLimits() {
        guard isDemo else { return }
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
        if paused, var session = activeSession {
            session.endedAt = .now
            save(session)
        } else if !paused, isDemo, let last = todaySessions.last {
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
    /// Fase 1: ainda sem coletor, então o app abre em modo demonstração por padrão.
    /// `--no-demo` abre o banco real (vazio até a Fase 2).
    static var isDemo: Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--no-demo") { return false }
        return true
    }
}
