import Foundation

/// Evento útil de uma linha do JSONL do Claude Code. Só metadados: o conteúdo da mensagem
/// (`message.content`) não é declarado no `Decodable` e por isso nunca é lido para fora do parser.
public struct ClaudeCodeEvent: Equatable, Sendable {
    public var timestamp: Date
    public var sessionId: String?
    public var cwd: String?
    public var entrypoint: String?
    public var messageId: String?
    /// input + output + criação de cache (leitura de cache não conta para limite).
    public var tokens: Int
    public var isAssistant: Bool
}

public enum ClaudeCodeLogParser {
    private struct Line: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                var input_tokens: Int?
                var output_tokens: Int?
                var cache_creation_input_tokens: Int?
            }

            var id: String?
            var usage: Usage?
        }

        var type: String?
        var timestamp: String?
        var sessionId: String?
        var cwd: String?
        var entrypoint: String?
        var isSidechain: Bool?
        var message: Message?
    }

    private static let decoder = JSONDecoder()

    /// `nil` para linhas que não são `user`/`assistant`, de subagentes (`isSidechain`) ou inválidas.
    public static func parse(_ line: Data) -> ClaudeCodeEvent? {
        guard let decoded = try? decoder.decode(Line.self, from: line),
              decoded.type == "user" || decoded.type == "assistant",
              decoded.isSidechain != true,
              let timestamp = decoded.timestamp.flatMap(ISO8601.parse)
        else { return nil }

        let usage = decoded.message?.usage
        let tokens = (usage?.input_tokens ?? 0) + (usage?.output_tokens ?? 0) + (usage?.cache_creation_input_tokens ?? 0)
        return ClaudeCodeEvent(
            timestamp: timestamp,
            sessionId: decoded.sessionId,
            cwd: decoded.cwd,
            entrypoint: decoded.entrypoint,
            messageId: decoded.message?.id,
            tokens: decoded.type == "assistant" ? tokens : 0,
            isAssistant: decoded.type == "assistant"
        )
    }

    /// Rótulo de origem a partir do `entrypoint` do Claude Code.
    public static func sourceLabel(entrypoint: String?) -> String {
        let value = (entrypoint ?? "").lowercased()
        if value.isEmpty || value == "cli" { return "Claude Code · Terminal" }
        if value.contains("vscode") { return "Claude Code · VS Code" }
        if value.contains("jetbrains") { return "Claude Code · JetBrains" }
        if value.contains("desktop") { return "Claude Code · App Claude" }
        if value.contains("sdk") { return "Claude Code · SDK" }
        return "Claude Code"
    }
}

/// Entrada do `logs.json` do Gemini CLI (formato não verificado nesta máquina: parser tolerante).
public struct GeminiCLIEntry: Equatable, Sendable {
    public var type: String?
    public var timestamp: Date
    public var sessionId: String?
}

public enum GeminiCLILogParser {
    /// Aceita um array de objetos ou um objeto com o array em `messages`/`history`/`entries`.
    /// Lê só `type`, `timestamp` e `sessionId`; o texto do prompt é ignorado.
    public static func parse(_ data: Data) -> [GeminiCLIEntry]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let array: [Any]
        if let list = json as? [Any] {
            array = list
        } else if let object = json as? [String: Any],
                  let list = (object["messages"] ?? object["history"] ?? object["entries"]) as? [Any] {
            array = list
        } else {
            return nil
        }
        return array.compactMap { item in
            guard let entry = item as? [String: Any],
                  let timestamp = (entry["timestamp"] as? String).flatMap(ISO8601.parse)
            else { return nil }
            return GeminiCLIEntry(
                type: entry["type"] as? String,
                timestamp: timestamp,
                sessionId: entry["sessionId"] as? String
            )
        }
    }
}

enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}

public enum TokenBuckets {
    /// Chave horária em UTC: `2026-10-05T14`.
    public static func hourKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d-%02d-%02dT%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
    }
}
