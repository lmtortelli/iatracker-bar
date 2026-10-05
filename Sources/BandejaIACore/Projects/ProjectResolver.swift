import Foundation

/// Atribui projeto a uma sessão nova (CLAUDE.md › Atribuição de projeto):
/// 1. `manual_project` é preservado por quem chama (o resolvedor só roda para sessões novas);
/// 2. `cwd` → raiz git → regra `cwd` ou nome da pasta;
/// 3. regras de domínio / título;
/// 4. último projeto usado.
public struct ProjectResolver {
    public enum Resolution: Equatable {
        case project(Int64)
        /// Projeto ainda inexistente, nomeado pela pasta.
        case newProject(String)
        case none
    }

    public var rules: [ProjectRule]
    public var lastProjectId: Int64?
    public var homeDirectory: String
    /// Raiz do repositório git que contém o caminho, se houver.
    public var gitRoot: (String) -> String?

    public init(
        rules: [ProjectRule],
        lastProjectId: Int64?,
        homeDirectory: String = NSHomeDirectory(),
        gitRoot: @escaping (String) -> String? = GitRoot.find
    ) {
        self.rules = rules
        self.lastProjectId = lastProjectId
        self.homeDirectory = homeDirectory
        self.gitRoot = gitRoot
    }

    public func resolve(_ detection: Detection) -> Resolution {
        if let cwd = detection.cwd.map(expand) {
            let root = gitRoot(cwd) ?? cwd
            if let rule = rules.first(where: { $0.kind == .cwd && (matches(path: $0.pattern, root) || matches(path: $0.pattern, cwd)) }) {
                return .project(rule.projectId)
            }
            let name = (root as NSString).lastPathComponent
            return name.isEmpty || name == "/" ? fallback : .newProject(name)
        }
        if let url = detection.url,
           let rule = rules.first(where: { $0.kind == .domain && Self.matches(domain: $0.pattern, url: url) }) {
            return .project(rule.projectId)
        }
        if let title = detection.title,
           let rule = rules.first(where: { $0.kind == .title && Self.matches(title: $0.pattern, in: title) }) {
            return .project(rule.projectId)
        }
        return fallback
    }

    private var fallback: Resolution {
        lastProjectId.map(Resolution.project) ?? .none
    }

    // MARK: Casamento

    /// `~/dev/site` casa com `~/dev/site` e `~/dev/site/sub`, mas não com `~/dev/site-2`.
    public func matches(path pattern: String, _ path: String) -> Bool {
        let pattern = expand(pattern.trimmingCharacters(in: .whitespaces))
        guard !pattern.isEmpty else { return false }
        let base = pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
        return path == base || path.hasPrefix(base + "/")
    }

    func expand(_ path: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory + path.dropFirst(1) }
        return path
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

public enum GitRoot {
    /// Sobe a partir de `path` procurando `.git` (pasta ou arquivo, no caso de worktrees).
    public static func find(from path: String) -> String? {
        find(from: path) { FileManager.default.fileExists(atPath: $0) }
    }

    public static func find(from path: String, exists: (String) -> Bool) -> String? {
        var current = (path as NSString).standardizingPath
        while !current.isEmpty, current != "/" {
            if exists((current as NSString).appendingPathComponent(".git")) {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}

/// Junta resolvedor + banco: devolve o id do projeto, criando-o quando a regra pede um projeto novo.
public enum ProjectAssigner {
    public static func projectID(for detection: Detection, in database: AppDatabase) throws -> Int64? {
        let resolver = ProjectResolver(rules: try database.rules(), lastProjectId: try database.lastProjectId())
        switch resolver.resolve(detection) {
        case let .project(id): return id
        case let .newProject(name): return try database.project(named: name).id
        case .none: return nil
        }
    }
}

public extension String {
    /// `/Users/eu/dev/x` → `~/dev/x`, para exibição.
    func abbreviatingHome(_ home: String = NSHomeDirectory()) -> String {
        if self == home { return "~" }
        return hasPrefix(home + "/") ? "~" + dropFirst(home.count) : self
    }
}
