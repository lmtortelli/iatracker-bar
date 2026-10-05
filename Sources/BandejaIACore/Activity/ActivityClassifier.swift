import Foundation

/// Navegadores cuja aba ativa é lida via AppleScript.
public enum Browser: String, CaseIterable, Sendable, Hashable {
    case safari = "com.apple.Safari"
    case chrome = "com.google.Chrome"
    case arc = "company.thebrowser.Browser"
    case brave = "com.brave.Browser"
    case edge = "com.microsoft.edgemac"

    public var bundleID: String { rawValue }

    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .arc: "Arc"
        case .brave: "Brave"
        case .edge: "Edge"
        }
    }

    /// Safari usa `front document`; os demais seguem o dicionário do Chromium.
    public var isChromium: Bool { self != .safari }
}

/// O que estava em foco num instante. Título e URL servem só para classificar e atribuir projeto:
/// nunca são gravados.
public struct FocusSnapshot: Equatable, Sendable {
    public var bundleID: String?
    public var url: URL?
    public var title: String?

    public init(bundleID: String?, url: URL? = nil, title: String? = nil) {
        self.bundleID = bundleID
        self.url = url
        self.title = title
    }
}

/// Uso de IA detectado: operador + rótulo de origem (`claude.ai · Safari`).
public struct Detection: Equatable, Sendable {
    public var provider: ProviderID
    public var source: String
    public var url: URL?
    public var title: String?
    public var cwd: String?

    public init(provider: ProviderID, source: String, url: URL? = nil, title: String? = nil, cwd: String? = nil) {
        self.provider = provider
        self.source = source
        self.url = url
        self.title = title
        self.cwd = cwd
    }

    /// Duas detecções são a mesma sessão quando operador e origem coincidem.
    public func isSameOrigin(as session: Session) -> Bool {
        provider == session.provider && source == session.source
    }
}

public enum ActivityClassifier {
    public static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// Terminais e editores: o uso vem dos logs locais (Fase 3), não da janela em foco.
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "com.microsoft.VSCode",
    ]

    private static let hosts: [(suffix: String, provider: ProviderID)] = [
        ("claude.ai", .claude),
        ("gemini.google.com", .gemini),
        ("aistudio.google.com", .gemini),
    ]

    /// Remove a detecção por foco do app Claude quando o mesmo uso já está sendo contado
    /// pelos logs do Claude Code rodando dentro do app (evita contar o tempo duas vezes).
    public static func deduplicate(_ detection: Detection?, openSessions: [Session]) -> Detection? {
        guard let detection, detection.source == "App Claude" else { return detection }
        let desktopCode = ClaudeCodeLogParser.sourceLabel(entrypoint: "claude-desktop")
        return openSessions.contains { $0.source == desktopCode } ? nil : detection
    }

    public static func classify(_ snapshot: FocusSnapshot) -> Detection? {
        guard let bundleID = snapshot.bundleID else { return nil }

        if bundleID == claudeDesktopBundleID {
            return Detection(provider: .claude, source: "App Claude", title: snapshot.title)
        }

        guard let browser = Browser(rawValue: bundleID),
              let url = snapshot.url,
              let host = url.host?.lowercased()
        else { return nil }

        for entry in hosts where host == entry.suffix || host.hasSuffix("." + entry.suffix) {
            return Detection(
                provider: entry.provider,
                source: "\(entry.suffix) · \(browser.displayName)",
                url: url,
                title: snapshot.title
            )
        }
        return nil
    }
}
