import Foundation
import GRDB

/// Acesso ao SQLite do app. Toda leitura/escrita passa por aqui.
public final class AppDatabase: Sendable {
    private let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Migrations.migrator.migrate(writer)
    }

    /// Banco em `~/Library/Application Support/IAtracker-bar/iatracker.sqlite`.
    public static func onDisk() throws -> AppDatabase {
        let support = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("IAtracker-bar", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("iatracker.sqlite")
        migrateLegacyDatabase(from: support.appendingPathComponent("BandejaIA", isDirectory: true), to: file)
        let pool = try DatabasePool(path: file.path)
        return try AppDatabase(pool)
    }

    /// O projeto se chamava "Bandeja IA": traz o banco antigo na primeira execução com o nome novo.
    static func migrateLegacyDatabase(from legacyFolder: URL, to file: URL) {
        let manager = FileManager.default
        let legacy = legacyFolder.appendingPathComponent("bandeja.sqlite")
        guard manager.fileExists(atPath: legacy.path), !manager.fileExists(atPath: file.path) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: legacy.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            try? manager.moveItem(at: source, to: URL(fileURLWithPath: file.path + suffix))
        }
        try? manager.removeItem(at: legacyFolder)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    // MARK: Projetos

    /// Retorna o projeto com esse nome, criando se não existir.
    @discardableResult
    public func project(named name: String) throws -> Project {
        try writer.write { db in
            if let existing = try Project.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            var project = Project(name: name)
            try project.insert(db)
            return project
        }
    }

    public func projects() throws -> [Project] {
        try writer.read { db in
            try Project.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }
    }

    /// Renomeia; se já houver outro projeto com o nome, junta os dois (sessões e regras vão para ele).
    /// Retorna o id do projeto resultante.
    @discardableResult
    public func renameProject(id: Int64, to name: String) throws -> Int64 {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try writer.write { db in
            guard !name.isEmpty else { return id }
            if let other = try Project.filter(Column("name") == name && Column("id") != id).fetchOne(db),
               let otherId = other.id {
                try db.execute(sql: "UPDATE session SET project_id = ? WHERE project_id = ?", arguments: [otherId, id])
                try db.execute(sql: "UPDATE project_rule SET project_id = ? WHERE project_id = ?", arguments: [otherId, id])
                _ = try Project.deleteOne(db, key: id)
                return otherId
            }
            try db.execute(sql: "UPDATE project SET name = ? WHERE id = ?", arguments: [name, id])
            return id
        }
    }

    /// Exclui o projeto: sessões ficam sem projeto, regras são removidas (chaves estrangeiras).
    public func deleteProject(id: Int64) throws {
        _ = try writer.write { db in try Project.deleteOne(db, key: id) }
    }

    public func rules() throws -> [ProjectRule] {
        try writer.read { db in try ProjectRule.fetchAll(db) }
    }

    @discardableResult
    public func insert(_ rule: ProjectRule) throws -> ProjectRule {
        try writer.write { db in
            var rule = rule
            try rule.insert(db)
            return rule
        }
    }

    public func deleteRule(id: Int64) throws {
        _ = try writer.write { db in try ProjectRule.deleteOne(db, key: id) }
    }

    // MARK: Sessões

    @discardableResult
    public func insert(_ session: Session) throws -> Session {
        try writer.write { db in
            var session = session
            try session.insert(db)
            return session
        }
    }

    public func update(_ session: Session) throws {
        try writer.write { db in try session.update(db) }
    }

    /// Altera só o fim da sessão (`nil` reabre), sem sobrescrever projeto escolhido em outro lugar.
    /// Retorna `false` se a sessão não existe mais.
    @discardableResult
    public func setSessionEnd(id: Int64, at end: Date?) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: "UPDATE session SET ended_at = ? WHERE id = ?", arguments: [end, id])
            return db.changesCount > 0
        }
    }

    public func deleteSession(id: Int64) throws {
        _ = try writer.write { db in try Session.deleteOne(db, key: id) }
    }

    /// Sessões que tocam o intervalo `[start, end)`, mais antigas primeiro.
    public func sessions(from start: Date, to end: Date) throws -> [Session] {
        try writer.read { db in
            try Session
                .filter(Column("started_at") < end)
                .filter(Column("ended_at") == nil || Column("ended_at") > start)
                .order(Column("started_at"))
                .fetchAll(db)
        }
    }

    public func session(id: Int64) throws -> Session? {
        try writer.read { db in try Session.fetchOne(db, key: id) }
    }

    /// Projeto da sessão mais recente que tem projeto (regra "último projeto usado").
    public func lastProjectId() throws -> Int64? {
        try writer.read { db in
            try Session
                .filter(Column("project_id") != nil)
                .order(Column("started_at").desc)
                .fetchOne(db)?
                .projectId
        }
    }

    /// Sessões abertas (sem `ended_at`). Normalmente zero ou uma.
    public func openSessions() throws -> [Session] {
        try writer.read { db in
            try Session.filter(Column("ended_at") == nil).fetchAll(db)
        }
    }

    /// Pastas de trabalho já vistas (para casar o hash de projeto do Gemini CLI).
    public func distinctCwds() throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT cwd FROM session WHERE cwd IS NOT NULL")
        }
    }

    // MARK: Cursores de log

    public func cursor(for path: String) throws -> LogCursor? {
        try writer.read { db in try LogCursor.fetchOne(db, key: path) }
    }

    public func cursors() throws -> [LogCursor] {
        try writer.read { db in try LogCursor.fetchAll(db) }
    }

    public func save(_ cursor: LogCursor) throws {
        try writer.write { db in try cursor.save(db) }
    }

    // MARK: Contadores

    public func increment(_ provider: ProviderID, _ kind: Counter.Kind, day: String, by amount: Int = 1) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO counter (provider, kind, day, value) VALUES (?, ?, ?, ?)
                ON CONFLICT(provider, kind, day) DO UPDATE SET value = value + excluded.value
                """,
                arguments: [provider, kind, day, amount]
            )
        }
    }

    public func counter(_ provider: ProviderID, _ kind: Counter.Kind, day: String) throws -> Int {
        try writer.read { db in
            try Counter
                .filter(Column("provider") == provider && Column("kind") == kind && Column("day") == day)
                .fetchOne(db)?.value ?? 0
        }
    }

    /// Vários contadores de uma vez (ex.: as 5 horas da janela do Claude).
    public func counters(_ provider: ProviderID, _ kind: Counter.Kind, days: [String]) throws -> [String: Int] {
        try writer.read { db in
            let rows = try Counter
                .filter(Column("provider") == provider && Column("kind") == kind && days.contains(Column("day")))
                .fetchAll(db)
            return Dictionary(rows.map { ($0.day, $0.value) }, uniquingKeysWith: +)
        }
    }

    // MARK: Limites

    /// Grava os snapshots de uma consulta e descarta os com mais de 7 dias.
    public func save(_ snapshots: [LimitSnapshot], pruneBefore: Date) throws {
        try writer.write { db in
            for var snapshot in snapshots { try snapshot.insert(db) }
            try LimitSnapshot.filter(Column("fetched_at") < pruneBefore).deleteAll(db)
        }
    }

    public func insert(_ snapshot: LimitSnapshot) throws {
        try writer.write { db in
            var snapshot = snapshot
            try snapshot.insert(db)
        }
    }

    /// Último snapshot de cada janela do operador.
    public func latestSnapshots(for provider: ProviderID) throws -> [LimitSnapshot] {
        try writer.read { db in
            try LimitSnapshot.fetchAll(
                db,
                sql: """
                SELECT s.* FROM limit_snapshot s
                JOIN (SELECT window, MAX(fetched_at) AS f FROM limit_snapshot WHERE provider = ? GROUP BY window) m
                  ON s.window = m.window AND s.fetched_at = m.f
                WHERE s.provider = ?
                """,
                arguments: [provider, provider]
            )
        }
    }
}
