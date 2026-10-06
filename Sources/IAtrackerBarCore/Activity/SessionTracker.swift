import Foundation

/// Máquina de estados que transforma detecções periódicas em sessões no banco.
///
/// Regras (CLAUDE.md › Coleta de atividade):
/// - trocar de origem encerra a sessão atual e abre outra;
/// - ociosidade acima do limite encerra a sessão no instante do último evento;
/// - sessões com menos de `minDuration` são descartadas;
/// - voltar à mesma origem em até `resumeGap` retoma a sessão anterior
///   (evita picotar o uso quando se alterna rapidamente de janela).
public final class SessionTracker {
    public struct Config: Sendable {
        public var minDuration: TimeInterval
        public var resumeGap: TimeInterval

        public init(minDuration: TimeInterval = 30, resumeGap: TimeInterval = 60) {
            self.minDuration = minDuration
            self.resumeGap = resumeGap
        }
    }

    public private(set) var current: Session?
    private var lastEnded: Session?
    private let database: AppDatabase
    private let config: Config

    public init(database: AppDatabase, config: Config = Config()) {
        self.database = database
        self.config = config
    }

    /// Processa uma observação. Retorna `true` se o banco mudou.
    @discardableResult
    public func observe(
        _ detection: Detection?,
        at now: Date,
        idleSeconds: TimeInterval,
        idleThreshold: TimeInterval,
        resolveProject: (Detection) -> Int64?
    ) throws -> Bool {
        if idleSeconds >= idleThreshold {
            // Ocioso: encerra no último evento e não abre nada novo.
            return try end(at: now.addingTimeInterval(-idleSeconds))
        }

        guard let detection else {
            return try end(at: now)
        }

        if let current, detection.isSameOrigin(as: current) {
            return false
        }

        _ = try end(at: now)

        if var previous = lastEnded,
           let id = previous.id,
           detection.isSameOrigin(as: previous),
           let endedAt = previous.endedAt,
           now.timeIntervalSince(endedAt) <= config.resumeGap,
           try database.setSessionEnd(id: id, at: nil) {
            previous.endedAt = nil
            current = previous
            lastEnded = nil
            return true
        }

        current = try database.insert(Session(
            provider: detection.provider,
            source: detection.source,
            projectId: resolveProject(detection),
            cwd: detection.cwd,
            startedAt: now
        ))
        lastEnded = nil
        return true
    }

    /// Encerra a sessão ativa (pausa, repouso, saída do app). Retorna `true` se o banco mudou.
    @discardableResult
    public func stop(at now: Date) throws -> Bool {
        let changed = try end(at: now)
        lastEnded = nil
        return changed
    }

    private func end(at time: Date) throws -> Bool {
        guard var session = current else { return false }
        current = nil
        let end = max(session.startedAt, time)
        guard let id = session.id else { return false }

        if end.timeIntervalSince(session.startedAt) < config.minDuration {
            try database.deleteSession(id: id)
            lastEnded = nil
        } else if try database.setSessionEnd(id: id, at: end) {
            session.endedAt = end
            lastEnded = session
        } else {
            lastEnded = nil
        }
        return true
    }

    /// Fecha sessões que ficaram abertas porque o app foi encerrado à força.
    /// O fim é o último sinal de vida registrado (`heartbeat`); sem ele, a sessão é descartada.
    public static func recoverOrphans(
        in database: AppDatabase,
        heartbeat: Date?,
        now: Date,
        config: Config = Config()
    ) throws {
        for session in try database.openSessions() {
            guard let id = session.id else { continue }
            let end = min(max(heartbeat ?? session.startedAt, session.startedAt), now)
            if end.timeIntervalSince(session.startedAt) < config.minDuration {
                try database.deleteSession(id: id)
            } else {
                try database.setSessionEnd(id: id, at: end)
            }
        }
    }
}
