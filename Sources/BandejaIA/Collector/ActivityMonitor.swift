import AppKit
import BandejaIACore
import os

/// Coletor: a cada 5 s (e a cada troca de app) observa o que está em foco e alimenta o `SessionTracker`.
@MainActor
final class ActivityMonitor {
    static let tickInterval: TimeInterval = 5
    private static let heartbeatKey = "lastHeartbeat"

    /// Chamado quando sessões mudam no banco.
    var onChange: () -> Void = {}
    /// Navegadores em que a Automação foi negada (para avisar na interface).
    private(set) var automationDenied: Set<Browser> = [] {
        didSet { if automationDenied != oldValue { onAutomationChange(automationDenied) } }
    }
    var onAutomationChange: (Set<Browser>) -> Void = { _ in }

    private let database: AppDatabase
    private let tracker: SessionTracker
    private let tabReader = BrowserTabReader()
    private let logger = Logger(subsystem: "BandejaIA", category: "ActivityMonitor")
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var tickInFlight = false
    private var paused: Bool

    init(database: AppDatabase, paused: Bool) {
        self.database = database
        self.tracker = SessionTracker(database: database)
        self.paused = paused
    }

    func start() {
        let heartbeat = UserDefaults.standard.object(forKey: Self.heartbeatKey) as? Date
        performAndNotify { try SessionTracker.recoverOrphans(in: $0, heartbeat: heartbeat, now: .now) }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTick() }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopCurrent() }
            })
        }

        // Timer e observadores rodam na main thread (fila `.main` / RunLoop.main).
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        scheduleTick()
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            stopCurrent()
        } else {
            scheduleTick()
        }
    }

    /// Encerra a sessão ativa ao sair do app.
    func shutdown() {
        timer?.invalidate()
        stopCurrent()
    }

    // MARK: Tick

    private func scheduleTick() {
        Task { await tick() }
    }

    private func tick() async {
        guard !paused, !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.heartbeatKey)
        let idle = IdleDetector.secondsSinceLastInput()
        let threshold = Preferences.idleSeconds
        let app = NSWorkspace.shared.frontmostApplication

        var snapshot = FocusSnapshot(bundleID: app?.bundleIdentifier)
        if idle < threshold, let app {
            if let browser = app.bundleIdentifier.flatMap(Browser.init(rawValue:)) {
                switch await tabReader.read(browser) {
                case let .success(tab):
                    snapshot.url = tab.url
                    snapshot.title = tab.title
                    automationDenied.remove(browser)
                case .failure(.notAuthorized):
                    automationDenied.insert(browser)
                case .failure:
                    break
                }
            } else if app.bundleIdentifier == ActivityClassifier.claudeDesktopBundleID {
                snapshot.title = WindowTitleReader.focusedWindowTitle(pid: app.processIdentifier)
            }
        }
        // A leitura da aba é assíncrona: a pausa pode ter chegado no meio.
        guard !paused else { return }

        let detection = ActivityClassifier.deduplicate(
            ActivityClassifier.classify(snapshot),
            openSessions: (try? database.openSessions()) ?? []
        )
        perform { database in
            try tracker.observe(
                detection,
                at: now,
                idleSeconds: idle,
                idleThreshold: threshold,
                resolveProject: { detection in
                    (try? ProjectAssigner.projectID(for: detection, in: database)) ?? nil
                }
            )
        }
    }

    private func stopCurrent() {
        perform { [tracker] _ in try tracker.stop(at: .now) }
    }

    /// Executa uma escrita; erros de banco são registrados e nunca derrubam a interface.
    private func perform(_ work: (AppDatabase) throws -> Bool) {
        do {
            if try work(database) { onChange() }
        } catch {
            logger.error("Falha no coletor: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performAndNotify(_ work: (AppDatabase) throws -> Void) {
        perform { database -> Bool in
            try work(database)
            return true
        }
    }
}
