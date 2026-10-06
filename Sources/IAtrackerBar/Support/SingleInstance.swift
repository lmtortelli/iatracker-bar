import AppKit

/// Garante uma única cópia do app rodando (duas cópias contariam o uso em dobro).
/// O `Info.plist` já proíbe múltiplas instâncias via Launch Services (`LSMultipleInstancesProhibited`);
/// isto cobre os casos que passam por fora (`open -n`, executável chamado direto, cópia em outra pasta).
@MainActor
enum SingleInstance {
    /// Bundle do app quando ainda se chamava "Bandeja IA".
    static let legacyBundleID = "io.github.bandejaia"

    /// `true` se outra cópia já está aberta; nesse caso avisa a pessoa e encerra esta.
    static func handOffIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false } // `swift run`, sem bundle
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        guard !others.isEmpty else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "O IAtracker-bar já está aberto"
        alert.informativeText = "Ele fica na barra de menus, perto do relógio. Clique no item para ver os limites e o uso de hoje."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.terminate(nil)
        return true
    }

    /// Encerra o app com o nome antigo, se estiver aberto (o banco já foi migrado para este).
    static func terminateLegacyApp() {
        NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID).forEach { $0.terminate() }
    }
}
