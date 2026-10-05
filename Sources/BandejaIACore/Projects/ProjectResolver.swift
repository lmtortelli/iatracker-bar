import Foundation

/// Atribui projeto a uma sessão nova (CLAUDE.md › Atribuição de projeto).
///
/// Fase 2: regras de domínio e de título + último projeto usado.
/// A regra por `cwd`/raiz git entra na Fase 3, junto com os logs do Claude Code.
public struct ProjectResolver {
    public var rules: [ProjectRule]
    public var lastProjectId: Int64?

    public init(rules: [ProjectRule], lastProjectId: Int64?) {
        self.rules = rules
        self.lastProjectId = lastProjectId
    }

    public func resolve(_ detection: Detection) -> Int64? {
        if let url = detection.url,
           let rule = rules.first(where: { $0.kind == .domain && Self.matches(domain: $0.pattern, url: url) }) {
            return rule.projectId
        }
        if let title = detection.title,
           let rule = rules.first(where: { $0.kind == .title && Self.matches(title: $0.pattern, in: title) }) {
            return rule.projectId
        }
        return lastProjectId
    }

    /// `claude.ai` casa com o host (e subdomínios); `claude.ai/project/abc` casa com host + início do caminho.
    static func matches(domain pattern: String, url: URL) -> Bool {
        var pattern = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        for scheme in ["https://", "http://"] where pattern.hasPrefix(scheme) {
            pattern.removeFirst(scheme.count)
        }
        guard !pattern.isEmpty, let host = url.host?.lowercased() else { return false }

        if pattern.contains("/") {
            return (host + url.path.lowercased()).hasPrefix(pattern)
        }
        return host == pattern || host.hasSuffix("." + pattern)
    }

    static func matches(title pattern: String, in title: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }
        return title.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
