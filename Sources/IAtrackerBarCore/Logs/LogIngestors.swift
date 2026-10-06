import CryptoKit
import Foundation

/// Fonte de uso baseada em arquivos locais (Claude Code, Gemini CLI).
public protocol LogIngestor: AnyObject {
    /// Pasta observada.
    var root: URL { get }
    /// Lê o que é novo nos arquivos (`nil` = todos). Retorna `true` se o banco mudou.
    func ingest(_ files: [URL]?, now: Date) throws -> Bool
    /// Fecha sessões cujo último evento ficou para trás.
    func sweep(now: Date) throws -> Bool
    /// Pula para o fim de todos os arquivos (ao retomar de uma pausa).
    func fastForward(now: Date) throws
}

/// Transforma eventos de log em sessões: eventos com intervalo menor que `gap` formam uma sessão.
/// Enquanto a sessão pode receber eventos, `ended_at` fica `NULL` (aparece como "Detectando agora").
public final class LogSessionWriter {
    public struct Config: Sendable {
        public var gap: TimeInterval
        public var minDuration: TimeInterval

        public init(gap: TimeInterval = 120, minDuration: TimeInterval = 30) {
            self.gap = gap
            self.minDuration = minDuration
        }
    }

    private let database: AppDatabase
    private let config: Config
    private var reopened: Set<Int64> = []

    public init(database: AppDatabase, config: Config = Config()) {
        self.database = database
        self.config = config
    }

    /// Registra um evento. `makeSession` só é chamado quando uma sessão nova precisa ser criada.
    @discardableResult
    public func record(at time: Date, cursor: inout LogCursor, makeSession: () throws -> Session) throws -> Bool {
        if let id = cursor.sessionId, let last = cursor.lastEventAt, time.timeIntervalSince(last) < config.gap {
            if time > last { cursor.lastEventAt = time }
            guard !reopened.contains(id) else { return false }
            // Garante que a sessão está aberta (pode ter sido fechada por recuperação de órfãs).
            if try database.setSessionEnd(id: id, at: nil) {
                reopened.insert(id)
                return true
            }
            cursor.sessionId = nil
            cursor.lastEventAt = nil
        }

        try finalize(&cursor)
        var session = try makeSession()
        session.startedAt = time
        session.endedAt = nil
        session = try database.insert(session)
        cursor.sessionId = session.id
        cursor.lastEventAt = time
        if let id = session.id { reopened.insert(id) }
        return true
    }

    @discardableResult
    public func finalizeIfStale(_ cursor: inout LogCursor, now: Date) throws -> Bool {
        guard let last = cursor.lastEventAt, now.timeIntervalSince(last) >= config.gap else { return false }
        return try finalize(&cursor)
    }

    /// Fecha a sessão no último evento; descarta se ficou curta demais.
    @discardableResult
    public func finalize(_ cursor: inout LogCursor) throws -> Bool {
        defer {
            cursor.sessionId = nil
            cursor.lastEventAt = nil
        }
        guard let id = cursor.sessionId, let last = cursor.lastEventAt else { return false }
        reopened.remove(id)
        guard let session = try database.session(id: id) else { return false }
        if last.timeIntervalSince(session.startedAt) < config.minDuration {
            try database.deleteSession(id: id)
        } else {
            try database.setSessionEnd(id: id, at: last)
        }
        return true
    }
}

// MARK: - Claude Code

/// `~/.claude/projects/<cwd-com-hifens>/<sessionId>.jsonl` — lido por offset de bytes.
public final class ClaudeCodeIngestor: LogIngestor {
    public let root: URL
    /// Na primeira leitura, importa só o que cabe no relatório.
    public var backfill: TimeInterval = 30 * 24 * 3600

    private let database: AppDatabase
    private let writer: LogSessionWriter

    public init(
        database: AppDatabase,
        root: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects"),
        config: LogSessionWriter.Config = .init()
    ) {
        self.database = database
        // Caminhos resolvidos: FSEvents e o enumerador entregam caminhos reais (ex.: /private/var).
        self.root = root.resolvingSymlinksInPath()
        self.writer = LogSessionWriter(database: database, config: config)
    }

    public func files() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    @discardableResult
    public func ingest(_ files: [URL]?, now: Date) throws -> Bool {
        var changed = false
        for url in (files ?? self.files()) where url.pathExtension == "jsonl" {
            changed = try ingestFile(url, now: now) || changed
        }
        return changed
    }

    private func ingestFile(_ url: URL, now: Date) throws -> Bool {
        let url = url.resolvingSymlinksInPath()
        var cursor = try database.cursor(for: url.path) ?? LogCursor(path: url.path)
        let original = cursor
        var changed = false

        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let size = Int64(try handle.seekToEnd())
            if size < cursor.offset { cursor.offset = 0 } // arquivo truncado ou recriado
            if size > cursor.offset {
                try handle.seek(toOffset: UInt64(cursor.offset))
                let data = try handle.readToEnd() ?? Data()
                // Só linhas completas; o resto fica para a próxima leitura.
                if let newline = data.lastIndex(of: 0x0A) {
                    let consumed = data[data.startIndex...newline]
                    changed = try process(consumed, cursor: &cursor, now: now)
                    cursor.offset += Int64(consumed.count)
                }
            }
        }

        changed = try writer.finalizeIfStale(&cursor, now: now) || changed
        if cursor != original { try database.save(cursor) }
        return changed
    }

    private func process(_ data: Data, cursor: inout LogCursor, now: Date) throws -> Bool {
        let cutoff = now.addingTimeInterval(-backfill)
        var changed = false
        var seenMessages: Set<String> = []
        var tokensByHour: [String: Int] = [:]

        for line in data.split(separator: 0x0A) {
            guard let event = ClaudeCodeLogParser.parse(Data(line)), event.timestamp >= cutoff else { continue }

            // Uma resposta pode ocupar várias linhas com o mesmo `message.id`.
            if event.tokens > 0, let id = event.messageId, seenMessages.insert(id).inserted {
                tokensByHour[TokenBuckets.hourKey(event.timestamp), default: 0] += event.tokens
            }

            changed = try writer.record(at: event.timestamp, cursor: &cursor) {
                let source = ClaudeCodeLogParser.sourceLabel(entrypoint: event.entrypoint)
                let detection = Detection(provider: .claude, source: source, cwd: event.cwd)
                return Session(
                    provider: .claude,
                    source: source,
                    projectId: try ProjectAssigner.projectID(for: detection, in: database),
                    cwd: event.cwd,
                    startedAt: event.timestamp
                )
            } || changed
        }

        for (hour, tokens) in tokensByHour {
            try database.increment(.claude, .claudeCodeTokens, day: hour, by: tokens)
        }
        return changed
    }

    @discardableResult
    public func sweep(now: Date) throws -> Bool {
        var changed = false
        for var cursor in try database.cursors() where cursor.path.hasPrefix(root.path) && cursor.sessionId != nil {
            if try writer.finalizeIfStale(&cursor, now: now) {
                try database.save(cursor)
                changed = true
            }
        }
        return changed
    }

    public func fastForward(now: Date) throws {
        for url in files().map({ $0.resolvingSymlinksInPath() }) {
            var cursor = try database.cursor(for: url.path) ?? LogCursor(path: url.path)
            try writer.finalize(&cursor)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            cursor.offset = size
            try database.save(cursor)
        }
    }
}

// MARK: - Gemini CLI

/// `~/.gemini/tmp/<sha256 da pasta do projeto>/logs.json` — array reescrito inteiro;
/// o cursor guarda quantas entradas já foram processadas. Conta prompts do usuário por dia de cota.
public final class GeminiCLIIngestor: LogIngestor {
    public static let source = "Gemini CLI · Terminal"

    public let root: URL
    public var backfill: TimeInterval = 30 * 24 * 3600

    private let database: AppDatabase
    private let writer: LogSessionWriter

    public init(
        database: AppDatabase,
        root: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/tmp"),
        config: LogSessionWriter.Config = .init()
    ) {
        self.database = database
        // Caminhos resolvidos: FSEvents e o enumerador entregam caminhos reais (ex.: /private/var).
        self.root = root.resolvingSymlinksInPath()
        self.writer = LogSessionWriter(database: database, config: config)
    }

    public func files() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .map { $0.appendingPathComponent("logs.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    public func ingest(_ files: [URL]?, now: Date) throws -> Bool {
        var changed = false
        for url in (files ?? self.files()) where url.lastPathComponent == "logs.json" {
            changed = try ingestFile(url, now: now) || changed
        }
        return changed
    }

    private func ingestFile(_ url: URL, now: Date) throws -> Bool {
        let url = url.resolvingSymlinksInPath()
        var cursor = try database.cursor(for: url.path) ?? LogCursor(path: url.path)
        let original = cursor
        var changed = false

        if let data = try? Data(contentsOf: url), let entries = GeminiCLILogParser.parse(data) {
            if entries.count < cursor.offset { cursor.offset = 0 } // histórico limpo
            let cutoff = now.addingTimeInterval(-backfill)
            let fresh = entries.dropFirst(Int(cursor.offset)).filter { $0.type == "user" && $0.timestamp >= cutoff }
            var perDay: [String: Int] = [:]
            let cwd = fresh.isEmpty ? nil : try projectPath(forHash: url.deletingLastPathComponent().lastPathComponent)

            for entry in fresh {
                perDay[GeminiQuota.quotaDay(for: entry.timestamp), default: 0] += 1
                changed = try writer.record(at: entry.timestamp, cursor: &cursor) {
                    let detection = Detection(provider: .gemini, source: Self.source, cwd: cwd)
                    return Session(
                        provider: .gemini,
                        source: Self.source,
                        projectId: try ProjectAssigner.projectID(for: detection, in: database),
                        cwd: cwd,
                        startedAt: entry.timestamp
                    )
                } || changed
            }
            for (day, count) in perDay {
                try database.increment(.gemini, .cliRequests, day: day, by: count)
                changed = true
            }
            cursor.offset = Int64(entries.count)
        }

        changed = try writer.finalizeIfStale(&cursor, now: now) || changed
        if cursor != original { try database.save(cursor) }
        return changed
    }

    /// O Gemini CLI nomeia a pasta com o SHA-256 do caminho do projeto: tenta as pastas já conhecidas.
    func projectPath(forHash hash: String) throws -> String? {
        let home = NSHomeDirectory()
        var candidates = Set(try database.distinctCwds())
        for rule in try database.rules() where rule.kind == .cwd {
            candidates.insert(rule.pattern.hasPrefix("~/") ? home + rule.pattern.dropFirst() : rule.pattern)
        }
        return candidates.first { Self.sha256($0) == hash.lowercased() }
    }

    public static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public func sweep(now: Date) throws -> Bool {
        var changed = false
        for var cursor in try database.cursors() where cursor.path.hasPrefix(root.path) && cursor.sessionId != nil {
            if try writer.finalizeIfStale(&cursor, now: now) {
                try database.save(cursor)
                changed = true
            }
        }
        return changed
    }

    public func fastForward(now: Date) throws {
        for url in files().map({ $0.resolvingSymlinksInPath() }) {
            var cursor = try database.cursor(for: url.path) ?? LogCursor(path: url.path)
            try writer.finalize(&cursor)
            if let data = try? Data(contentsOf: url), let entries = GeminiCLILogParser.parse(data) {
                cursor.offset = Int64(entries.count)
            }
            try database.save(cursor)
        }
    }
}
