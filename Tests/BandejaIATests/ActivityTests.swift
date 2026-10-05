import BandejaIACore
import Foundation

enum ActivityClassifierTests {
    static func snapshot(_ browser: Browser, _ url: String, title: String? = nil) -> FocusSnapshot {
        FocusSnapshot(bundleID: browser.bundleID, url: URL(string: url), title: title)
    }

    static let all: [TestCase] = [
        ("app Claude", {
            let detection = ActivityClassifier.classify(FocusSnapshot(bundleID: ActivityClassifier.claudeDesktopBundleID))
            expectEqual(detection?.provider, .claude)
            expectEqual(detection?.source, "App Claude")
        }),
        ("claude.ai nos navegadores", {
            expectEqual(ActivityClassifier.classify(snapshot(.safari, "https://claude.ai/chat/abc"))?.source, "claude.ai · Safari")
            expectEqual(ActivityClassifier.classify(snapshot(.arc, "https://claude.ai/new"))?.source, "claude.ai · Arc")
            expectEqual(ActivityClassifier.classify(snapshot(.chrome, "https://claude.ai/"))?.provider, .claude)
        }),
        ("gemini e ai studio", {
            let gemini = ActivityClassifier.classify(snapshot(.chrome, "https://gemini.google.com/app/123"))
            expectEqual(gemini?.provider, .gemini)
            expectEqual(gemini?.source, "gemini.google.com · Chrome")
            expectEqual(ActivityClassifier.classify(snapshot(.edge, "https://aistudio.google.com/prompts"))?.source, "aistudio.google.com · Edge")
        }),
        ("app Claude não conta em dobro com Claude Code rodando no próprio app", {
            let app = ActivityClassifier.classify(FocusSnapshot(bundleID: ActivityClassifier.claudeDesktopBundleID))
            let code = Session(provider: .claude, source: "Claude Code · App Claude", startedAt: date(2026, 10, 5, 9, 0))
            let terminal = Session(provider: .claude, source: "Claude Code · Terminal", startedAt: date(2026, 10, 5, 9, 0))
            expect(ActivityClassifier.deduplicate(app, openSessions: [code]) == nil)
            expectEqual(ActivityClassifier.deduplicate(app, openSessions: [terminal])?.source, "App Claude")
            let web = ActivityClassifier.classify(snapshot(.safari, "https://claude.ai/"))
            expectEqual(ActivityClassifier.deduplicate(web, openSessions: [code])?.source, "claude.ai · Safari")
        }),
        ("ignora outros sites, apps e terminais", {
            expect(ActivityClassifier.classify(snapshot(.safari, "https://google.com/search?q=claude.ai")) == nil)
            expect(ActivityClassifier.classify(snapshot(.safari, "https://notclaude.ai/")) == nil)
            expect(ActivityClassifier.classify(FocusSnapshot(bundleID: "com.apple.Terminal")) == nil)
            expect(ActivityClassifier.classify(FocusSnapshot(bundleID: "com.apple.Safari")) == nil)
            expect(ActivityClassifier.classify(FocusSnapshot(bundleID: nil)) == nil)
        }),
    ]
}

enum SessionTrackerTests {
    static let claudeWeb = Detection(provider: .claude, source: "claude.ai · Safari")
    static let geminiWeb = Detection(provider: .gemini, source: "gemini.google.com · Chrome")
    static let t0 = date(2026, 10, 5, 9, 0)

    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Simula ticks de 5 s com a mesma detecção, sem ociosidade.
    static func run(_ tracker: SessionTracker, _ detection: Detection?, from start: TimeInterval, to end: TimeInterval, project: Int64? = nil) throws {
        var t = start
        while t <= end {
            try tracker.observe(detection, at: at(t), idleSeconds: 0, idleThreshold: 120, resolveProject: { _ in project })
            t += 5
        }
    }

    static func all_sessions(_ db: AppDatabase) throws -> [Session] {
        try db.sessions(from: date(2026, 10, 1), to: date(2026, 10, 10))
    }

    static let all: [TestCase] = [
        ("abre, mantém e encerra ao sair do site", {
            let db = try AppDatabase.inMemory()
            let tracker = SessionTracker(database: db)
            let project = try db.project(named: "Site Lumen")
            try run(tracker, claudeWeb, from: 0, to: 300, project: project.id)
            expectEqual(try all_sessions(db).count, 1)
            expect(try all_sessions(db)[0].endedAt == nil)
            expectEqual(try all_sessions(db)[0].projectId, project.id)

            try tracker.observe(nil, at: at(305), idleSeconds: 0, idleThreshold: 120, resolveProject: { _ in nil })
            let session = try all_sessions(db)[0]
            expectEqual(session.endedAt, at(305))
        }),
        ("troca de origem fecha uma e abre outra", {
            let db = try AppDatabase.inMemory()
            let tracker = SessionTracker(database: db)
            try run(tracker, claudeWeb, from: 0, to: 120)
            try run(tracker, geminiWeb, from: 125, to: 300)
            let sessions = try all_sessions(db)
            expectEqual(sessions.map(\.provider), [.claude, .gemini])
            expectEqual(sessions[0].endedAt, at(125))
            expectEqual(sessions[1].startedAt, at(125))
        }),
        ("sessão com menos de 30 s é descartada", {
            let db = try AppDatabase.inMemory()
            let tracker = SessionTracker(database: db)
            try run(tracker, claudeWeb, from: 0, to: 20)
            try tracker.observe(nil, at: at(25), idleSeconds: 0, idleThreshold: 120, resolveProject: { _ in nil })
            expectEqual(try all_sessions(db).count, 0)
        }),
        ("ociosidade encerra no último evento", {
            let db = try AppDatabase.inMemory()
            let tracker = SessionTracker(database: db)
            try run(tracker, claudeWeb, from: 0, to: 600)
            // Às 600 s + 150 s, 150 s sem entrada: fim = 600 s.
            try tracker.observe(claudeWeb, at: at(750), idleSeconds: 150, idleThreshold: 120, resolveProject: { _ in nil })
            expectEqual(try all_sessions(db)[0].endedAt, at(600))
            // Continua ocioso: não abre outra.
            try tracker.observe(claudeWeb, at: at(800), idleSeconds: 200, idleThreshold: 120, resolveProject: { _ in nil })
            expectEqual(try all_sessions(db).count, 1)
        }),
        ("voltar à mesma origem em até 60 s retoma a sessão", {
            let db = try AppDatabase.inMemory()
            let tracker = SessionTracker(database: db)
            try run(tracker, claudeWeb, from: 0, to: 300)
            try tracker.observe(nil, at: at(305), idleSeconds: 0, idleThreshold: 120, resolveProject: { _ in nil })
            try run(tracker, claudeWeb, from: 340, to: 400)
            let sessions = try all_sessions(db)
            expectEqual(sessions.count, 1)
            expect(sessions[0].endedAt == nil)
            expectEqual(sessions[0].startedAt, at(0))
        }),
        ("depois de 60 s abre sessão nova", {
            let db = try AppDatabase.inMemory()
            let tracker = SessionTracker(database: db)
            try run(tracker, claudeWeb, from: 0, to: 300)
            try tracker.observe(nil, at: at(305), idleSeconds: 0, idleThreshold: 120, resolveProject: { _ in nil })
            try run(tracker, claudeWeb, from: 400, to: 500)
            expectEqual(try all_sessions(db).count, 2)
        }),
        ("encerrar não sobrescreve projeto escolhido manualmente", {
            let db = try AppDatabase.inMemory()
            let tracker = SessionTracker(database: db)
            try run(tracker, claudeWeb, from: 0, to: 120)
            let manual = try db.project(named: "Escolhido")
            var session = try all_sessions(db)[0]
            session.projectId = manual.id
            session.manualProject = true
            try db.update(session)
            try tracker.stop(at: at(200))
            let stored = try all_sessions(db)[0]
            expectEqual(stored.projectId, manual.id)
            expect(stored.manualProject)
            expectEqual(stored.endedAt, at(200))
        }),
        ("recupera sessões órfãs pelo heartbeat", {
            let db = try AppDatabase.inMemory()
            try db.insert(Session(provider: .claude, source: "a", startedAt: at(0)))
            try db.insert(Session(provider: .gemini, source: "b", startedAt: at(500)))
            try SessionTracker.recoverOrphans(in: db, heartbeat: at(510), now: at(3600))
            let sessions = try all_sessions(db)
            // A segunda tinha só 10 s até o heartbeat: descartada.
            expectEqual(sessions.map(\.source), ["a"])
            expectEqual(sessions[0].endedAt, at(510))
            expectEqual(try db.openSessions().count, 0)
        }),
    ]
}

enum ProjectResolverTests {
    static let rules = [
        ProjectRule(projectId: 1, kind: .domain, pattern: "gemini.google.com"),
        ProjectRule(projectId: 2, kind: .domain, pattern: "claude.ai/project/lumen"),
        ProjectRule(projectId: 3, kind: .title, pattern: "Finanças"),
        ProjectRule(projectId: 4, kind: .cwd, pattern: "~/dev/site-lumen"),
    ]

    static func detect(_ url: String?, title: String? = nil, cwd: String? = nil) -> Detection {
        Detection(provider: .claude, source: "x", url: url.flatMap(URL.init(string:)), title: title, cwd: cwd)
    }

    /// Repositórios fictícios: /Users/eu/dev/site-lumen e /Users/eu/dev/financas.
    static func resolver(last: Int64? = nil) -> ProjectResolver {
        let repos: Set<String> = ["/Users/eu/dev/site-lumen/.git", "/Users/eu/dev/financas/.git"]
        return ProjectResolver(rules: rules, lastProjectId: last, homeDirectory: "/Users/eu") { path in
            GitRoot.find(from: path) { repos.contains($0) }
        }
    }

    static let all: [TestCase] = [
        ("regra de domínio por host e por caminho", {
            let r = resolver(last: 9)
            expectEqual(r.resolve(detect("https://gemini.google.com/app/1")), .project(1))
            expectEqual(r.resolve(detect("https://claude.ai/project/lumen-site")), .project(2))
            expectEqual(r.resolve(detect("https://claude.ai/chat/1")), .project(9))
        }),
        ("regra de título ignora caixa e acento", {
            let r = resolver()
            expectEqual(r.resolve(detect(nil, title: "Planilha de financas — Claude")), .project(3))
            expectEqual(r.resolve(detect(nil, title: "Outra coisa")), .none)
        }),
        ("cwd sobe até a raiz git e usa a regra", {
            expectEqual(resolver().resolve(detect(nil, cwd: "/Users/eu/dev/site-lumen/src/app")), .project(4))
            expectEqual(resolver().resolve(detect(nil, cwd: "~/dev/site-lumen")), .project(4))
        }),
        ("cwd sem regra vira projeto com o nome da pasta do repositório", {
            expectEqual(resolver(last: 9).resolve(detect(nil, cwd: "/Users/eu/dev/financas/api")), .newProject("financas"))
            // Sem git, usa a própria pasta.
            expectEqual(resolver().resolve(detect(nil, cwd: "/Users/eu/scratch")), .newProject("scratch"))
        }),
        ("regra de pasta não casa com prefixo parcial", {
            let r = resolver()
            expect(!r.matches(path: "~/dev/site-lumen", "/Users/eu/dev/site-lumen-2"))
            expect(r.matches(path: "~/dev/site-lumen/", "/Users/eu/dev/site-lumen"))
        }),
        ("último projeto usado vem do banco", {
            let db = try AppDatabase.inMemory()
            let a = try db.project(named: "A")
            let b = try db.project(named: "B")
            try db.insert(Session(provider: .claude, source: "x", projectId: a.id, startedAt: date(2026, 10, 5, 9, 0), endedAt: date(2026, 10, 5, 9, 30)))
            try db.insert(Session(provider: .claude, source: "x", projectId: b.id, startedAt: date(2026, 10, 5, 10, 0), endedAt: date(2026, 10, 5, 10, 30)))
            try db.insert(Session(provider: .claude, source: "x", startedAt: date(2026, 10, 5, 11, 0)))
            expectEqual(try db.lastProjectId(), b.id)
        }),
        ("abrevia a pasta pessoal", {
            expectEqual("/Users/eu/dev/x".abbreviatingHome("/Users/eu"), "~/dev/x")
            expectEqual("/tmp/x".abbreviatingHome("/Users/eu"), "/tmp/x")
        }),
    ]
}
