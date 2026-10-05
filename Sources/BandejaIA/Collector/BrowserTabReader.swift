import AppKit
import BandejaIACore
import os

/// Lê URL e título da aba ativa via AppleScript (requer permissão de Automação por navegador).
/// Os scripts rodam numa fila própria: um navegador travado não congela a interface.
final class BrowserTabReader: @unchecked Sendable {
    struct Tab: Sendable {
        let url: URL?
        let title: String?
    }

    enum Failure: Error, Equatable {
        /// Usuário negou a Automação para este navegador (-1743).
        case notAuthorized
        case noWindow
        case script(Int)
    }

    private let queue = DispatchQueue(label: "BandejaIA.BrowserTabReader", qos: .utility)
    private var scripts: [Browser: NSAppleScript] = [:]
    private let logger = Logger(subsystem: "BandejaIA", category: "BrowserTabReader")

    func read(_ browser: Browser) async -> Result<Tab, Failure> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.readOnQueue(browser))
            }
        }
    }

    private func readOnQueue(_ browser: Browser) -> Result<Tab, Failure> {
        let script = scripts[browser] ?? NSAppleScript(source: Self.source(for: browser))
        guard let script else { return .failure(.script(0)) }
        scripts[browser] = script

        var error: NSDictionary?
        let output = script.executeAndReturnError(&error).stringValue ?? ""
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 { return .failure(.notAuthorized) }
            logger.debug("AppleScript \(browser.displayName, privacy: .public) falhou: \(code)")
            return .failure(.script(code))
        }
        guard !output.isEmpty else { return .failure(.noWindow) }

        let lines = output.components(separatedBy: "\n")
        return .success(Tab(
            url: lines.first.flatMap { URL(string: $0) },
            title: lines.count > 1 ? lines[1] : nil
        ))
    }

    static func source(for browser: Browser) -> String {
        let body = browser.isChromium
            ? """
              if (count of windows) is 0 then return ""
              set t to active tab of front window
              return (URL of t) & linefeed & (title of t)
              """
            : """
              if (count of documents) is 0 then return ""
              return (URL of front document) & linefeed & (name of front document)
              """
        return """
        with timeout of 3 seconds
          tell application id "\(browser.bundleID)"
            \(body)
          end tell
        end timeout
        """
    }
}
