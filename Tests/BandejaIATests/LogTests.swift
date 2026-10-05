import BandejaIACore
import Foundation

/// Pasta temporária com cópias das fixtures.
func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bandeja-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func lines(_ data: Data) -> [Data] {
    data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
}

private func sessions(_ db: AppDatabase) throws -> [Session] {
    try db.sessions(from: date(2026, 10, 1), to: date(2026, 10, 10))
}

enum ClaudeCodeLogTests {
    static let all: [TestCase] = [
        ("parser lê só metadados e descarta tipos irrelevantes e subagentes", {
            let all = lines(try fixture("claude_code_session.jsonl")).compactMap(ClaudeCodeLogParser.parse)
            // 10 linhas: queue-operation, attachment e sidechain ficam de fora.
            expectEqual(all.count, 7)
            expectEqual(all.first?.cwd, "/Users/eu/dev/site-lumen")
            expectEqual(all.first?.entrypoint, "cli")
            expectEqual(all[1].messageId, "msg_1")
            expectEqual(all[1].tokens, 160) // 100 + 50 + 10; leitura de cache não conta
            expectEqual(all[0].tokens, 0)
        }),
        ("rótulo de origem pelo entrypoint", {
            expectEqual(ClaudeCodeLogParser.sourceLabel(entrypoint: "cli"), "Claude Code · Terminal")
            expectEqual(ClaudeCodeLogParser.sourceLabel(entrypoint: nil), "Claude Code · Terminal")
            expectEqual(ClaudeCodeLogParser.sourceLabel(entrypoint: "claude-vscode"), "Claude Code · VS Code")
            expectEqual(ClaudeCodeLogParser.sourceLabel(entrypoint: "claude-desktop"), "Claude Code · App Claude")
            expectEqual(ClaudeCodeLogParser.sourceLabel(entrypoint: "algo-novo"), "Claude Code")
        }),
        ("ingestão agrupa eventos, descarta sessão curta e soma tokens sem duplicar", {
            let folder = try temporaryFolder()
            let file = folder.appendingPathComponent("proj/sessao.jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fixture("claude_code_session.jsonl").write(to: file)

            let db = try AppDatabase.inMemory()
            let ingestor = ClaudeCodeIngestor(database: db, root: folder)
            let changed = try ingestor.ingest(nil, now: date(2026, 10, 5, 12, 0))

            expect(changed)
            let stored = try sessions(db)
            // 12:00:00–12:02:00Z vira sessão; 12:10:00–12:10:05Z (5 s) é descartada.
            expectEqual(stored.count, 1)
            expectEqual(stored.first?.source, "Claude Code · Terminal")
            expectEqual(stored.first?.cwd, "/Users/eu/dev/site-lumen")
            expectEqual(stored.first?.endedAt?.timeIntervalSince(stored[0].startedAt), 120)
            // Sem `.git` real: projeto pelo nome da pasta.
            expectEqual(try db.projects().map(\.name), ["site-lumen"])
            // msg_1 (160, duas linhas) + msg_2 (300) + msg_3 (40); subagente fora.
            expectEqual(try db.counter(.claude, .claudeCodeTokens, day: "2026-10-05T12"), 500)

            // Releitura não duplica nada.
            expect(!(try ingestor.ingest(nil, now: date(2026, 10, 5, 12, 0))))
            expectEqual(try db.counter(.claude, .claudeCodeTokens, day: "2026-10-05T12"), 500)
        }),
        ("leitura incremental: sessão fica aberta e linha incompleta espera", {
            let folder = try temporaryFolder()
            let file = folder.appendingPathComponent("s.jsonl")
            let all = lines(try fixture("claude_code_session.jsonl"))
            // Até 12:01:30Z, mais metade da próxima linha.
            var partial = Data(all[0..<6].joined(separator: Data([0x0A])))
            partial.append(0x0A)
            partial.append(all[6].prefix(40))
            try partial.write(to: file)

            let db = try AppDatabase.inMemory()
            let ingestor = ClaudeCodeIngestor(database: db, root: folder)
            // "Agora" = 12:01:40Z (09:01:40 em São Paulo): ainda dentro do intervalo de 2 min.
            let now = date(2026, 10, 5, 9, 1).addingTimeInterval(40)
            try ingestor.ingest(nil, now: now)
            expect(try sessions(db).first?.endedAt == nil, "sessão deveria seguir aberta")

            // Completa a linha e acrescenta o resto.
            var rest = all[6].dropFirst(40)
            rest.append(0x0A)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: rest)
            try handle.write(contentsOf: Data(all[7...].joined(separator: Data([0x0A]))) + Data([0x0A]))
            try handle.close()

            try ingestor.ingest(nil, now: now.addingTimeInterval(30))
            let open = try sessions(db)
            expectEqual(open.count, 2) // a de 12:10Z abriu (ainda não sabe que será curta)

            // Depois do intervalo, o sweep fecha tudo e descarta a curta.
            try ingestor.sweep(now: date(2026, 10, 5, 12, 0))
            let closed = try sessions(db)
            expectEqual(closed.count, 1)
            expectEqual(closed.first?.endedAt?.timeIntervalSince(closed[0].startedAt), 120)
        }),
        ("pausa: avanço até o fim ignora o que foi escrito durante a pausa", {
            let folder = try temporaryFolder()
            try fixture("claude_code_session.jsonl").write(to: folder.appendingPathComponent("s.jsonl"))
            let db = try AppDatabase.inMemory()
            let ingestor = ClaudeCodeIngestor(database: db, root: folder)
            try ingestor.fastForward(now: date(2026, 10, 5, 12, 0))
            expect(!(try ingestor.ingest(nil, now: date(2026, 10, 5, 12, 0))))
            expectEqual(try sessions(db).count, 0)
        }),
        ("ignora eventos mais antigos que a janela de importação", {
            let folder = try temporaryFolder()
            try fixture("claude_code_session.jsonl").write(to: folder.appendingPathComponent("s.jsonl"))
            let db = try AppDatabase.inMemory()
            let ingestor = ClaudeCodeIngestor(database: db, root: folder)
            try ingestor.ingest(nil, now: date(2026, 12, 1))
            expectEqual(try sessions(db).count, 0)
        }),
    ]
}

enum GeminiCLILogTests {
    static let all: [TestCase] = [
        ("parser tolera array ou objeto e ignora o texto", {
            expectEqual(GeminiCLILogParser.parse(try fixture("gemini_logs.json"))?.count, 4)
            let wrapped = Data(#"{"messages":[{"type":"user","timestamp":"2026-10-05T12:00:00Z"}]}"#.utf8)
            expectEqual(GeminiCLILogParser.parse(wrapped)?.count, 1)
            expect(GeminiCLILogParser.parse(Data("não é json".utf8)) == nil)
        }),
        ("conta prompts por dia de cota, cria sessão e acha a pasta pelo hash", {
            let db = try AppDatabase.inMemory()
            let projectPath = "/Users/eu/dev/site-lumen"
            try db.insert(Session(provider: .claude, source: "x", cwd: projectPath, startedAt: date(2026, 10, 4, 9, 0), endedAt: date(2026, 10, 4, 10, 0)))

            let folder = try temporaryFolder()
            let hashFolder = folder.appendingPathComponent(GeminiCLIIngestor.sha256(projectPath))
            try FileManager.default.createDirectory(at: hashFolder, withIntermediateDirectories: true)
            let file = hashFolder.appendingPathComponent("logs.json")
            try fixture("gemini_logs.json").write(to: file)

            let ingestor = GeminiCLIIngestor(database: db, root: folder)
            try ingestor.ingest(nil, now: date(2026, 10, 5, 12, 0))
            expectEqual(try db.counter(.gemini, .cliRequests, day: "2026-10-05"), 3)
            let gemini = try sessions(db).filter { $0.provider == .gemini }
            expectEqual(gemini.count, 1)
            expectEqual(gemini.first?.cwd, projectPath)
            expectEqual(gemini.first?.endedAt?.timeIntervalSince(gemini[0].startedAt), 80)

            // Arquivo reescrito com uma entrada a mais: conta só a nova.
            var entries = try JSONSerialization.jsonObject(with: fixture("gemini_logs.json")) as? [[String: Any]] ?? []
            entries.append(["sessionId": "g-2", "type": "user", "timestamp": "2026-10-05T14:00:00.000Z"])
            try JSONSerialization.data(withJSONObject: entries).write(to: file)
            try ingestor.ingest(nil, now: date(2026, 10, 5, 12, 0))
            expectEqual(try db.counter(.gemini, .cliRequests, day: "2026-10-05"), 4)
        }),
    ]
}
