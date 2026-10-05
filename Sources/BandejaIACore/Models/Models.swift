import Foundation
import GRDB

/// Operador de IA monitorado.
public enum ProviderID: String, Codable, CaseIterable, Sendable, Hashable, DatabaseValueConvertible {
    case claude
    case gemini

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }

    public var initial: String { String(displayName.prefix(1)) }
}

/// De onde vem o dado de limite.
public enum LimitSource: String, Codable, Sendable, DatabaseValueConvertible {
    /// Consultado no serviço do operador.
    case official
    /// Calculado localmente (contagem de logs, cota configurada pelo usuário).
    case estimated

    public var badge: String {
        switch self {
        case .official: "OFICIAL"
        case .estimated: "ESTIMADO"
        }
    }
}

/// Faixa de consumo de uma janela de limite (define a cor).
public enum LimitLevel: Sendable, Equatable {
    case ok, warning, exceeded

    public init(percent: Double) {
        if percent >= 100 {
            self = .exceeded
        } else if percent >= 80 {
            self = .warning
        } else {
            self = .ok
        }
    }
}

// MARK: - Registros persistidos

private enum SnakeCaseRecord {
    static let decoding = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let encoding = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

public struct Session: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "session"
    public static let databaseColumnDecodingStrategy = SnakeCaseRecord.decoding
    public static let databaseColumnEncodingStrategy = SnakeCaseRecord.encoding

    public var id: Int64?
    public var provider: ProviderID
    /// Rótulo de origem, ex.: `claude.ai · Safari`, `Claude Code · Terminal`.
    public var source: String
    public var projectId: Int64?
    public var cwd: String?
    public var startedAt: Date
    /// `nil` enquanto a sessão está ativa.
    public var endedAt: Date?
    public var manualProject: Bool

    public init(
        id: Int64? = nil,
        provider: ProviderID,
        source: String,
        projectId: Int64? = nil,
        cwd: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        manualProject: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.source = source
        self.projectId = projectId
        self.cwd = cwd
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.manualProject = manualProject
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Duração em segundos; sessões abertas contam até `now`.
    public func duration(now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
}

public struct Project: Codable, Equatable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "project"

    public var id: Int64?
    public var name: String

    public init(id: Int64? = nil, name: String) {
        self.id = id
        self.name = name
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct ProjectRule: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "project_rule"
    public static let databaseColumnDecodingStrategy = SnakeCaseRecord.decoding
    public static let databaseColumnEncodingStrategy = SnakeCaseRecord.encoding

    public enum Kind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
        case cwd, domain, title
    }

    public var id: Int64?
    public var projectId: Int64
    public var kind: Kind
    public var pattern: String

    public init(id: Int64? = nil, projectId: Int64, kind: Kind, pattern: String) {
        self.id = id
        self.projectId = projectId
        self.kind = kind
        self.pattern = pattern
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Contadores diários (prompts do Gemini web, requisições do Gemini CLI).
public struct Counter: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "counter"

    public enum Kind: String, Codable, Sendable, DatabaseValueConvertible {
        case webPrompts = "web_prompts"
        case cliRequests = "cli_requests"
        /// Tokens do Claude Code por hora (`day` = `yyyy-MM-ddTHH` em UTC); base da estimativa de 5 h.
        case claudeCodeTokens = "claude_code_tokens"
    }

    public var id: Int64?
    public var provider: ProviderID
    public var kind: Kind
    /// Dia no formato `yyyy-MM-dd`, no fuso em que a cota é zerada.
    public var day: String
    public var value: Int

    public init(id: Int64? = nil, provider: ProviderID, kind: Kind, day: String, value: Int) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.day = day
        self.value = value
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct LimitSnapshot: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "limit_snapshot"
    public static let databaseColumnDecodingStrategy = SnakeCaseRecord.decoding
    public static let databaseColumnEncodingStrategy = SnakeCaseRecord.encoding

    public var id: Int64?
    public var provider: ProviderID
    public var window: String
    public var usedPct: Double
    public var resetAt: Date?
    public var source: LimitSource
    public var fetchedAt: Date

    public init(
        id: Int64? = nil,
        provider: ProviderID,
        window: String,
        usedPct: Double,
        resetAt: Date?,
        source: LimitSource,
        fetchedAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.window = window
        self.usedPct = usedPct
        self.resetAt = resetAt
        self.source = source
        self.fetchedAt = fetchedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Até onde um arquivo de log já foi lido e qual sessão ele está alimentando.
public struct LogCursor: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "log_cursor"
    public static let databaseColumnDecodingStrategy = SnakeCaseRecord.decoding
    public static let databaseColumnEncodingStrategy = SnakeCaseRecord.encoding

    public var path: String
    /// Bytes lidos (JSONL) ou entradas processadas (JSON em array).
    public var offset: Int64
    public var sessionId: Int64?
    public var lastEventAt: Date?

    public init(path: String, offset: Int64 = 0, sessionId: Int64? = nil, lastEventAt: Date? = nil) {
        self.path = path
        self.offset = offset
        self.sessionId = sessionId
        self.lastEventAt = lastEventAt
    }
}

// MARK: - Modelos de domínio (não persistidos diretamente)

/// Uma janela de limite de um operador, pronta para exibir.
public struct LimitWindow: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var usedPct: Double
    /// Texto secundário, ex.: `desde 11:05`, `38 de 100 prompts`.
    public var detail: String
    public var resetAt: Date?
    public var source: LimitSource
    public var updatedAt: Date

    public init(
        id: String,
        label: String,
        usedPct: Double,
        detail: String,
        resetAt: Date?,
        source: LimitSource,
        updatedAt: Date
    ) {
        self.id = id
        self.label = label
        self.usedPct = usedPct
        self.detail = detail
        self.resetAt = resetAt
        self.source = source
        self.updatedAt = updatedAt
    }

    public var level: LimitLevel { LimitLevel(percent: usedPct) }
}

public struct ProviderLimits: Equatable, Identifiable, Sendable {
    public var provider: ProviderID
    public var source: LimitSource
    public var windows: [LimitWindow]

    public var id: ProviderID { provider }

    public init(provider: ProviderID, source: LimitSource, windows: [LimitWindow]) {
        self.provider = provider
        self.source = source
        self.windows = windows
    }
}
