import AppKit
import ApplicationServices
import CoreGraphics

enum IdleDetector {
    /// Segundos desde o último evento de teclado/mouse/trackpad. Não exige permissão.
    static func secondsSinceLastInput() -> TimeInterval {
        // `kCGAnyInputEventType` (~0) cobre qualquer tipo de entrada.
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

enum WindowTitleReader {
    /// Título da janela em foco do app (requer Acessibilidade). Usado só para casar regras de título.
    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        // Tipo verificado acima pelo CFTypeID.
        let element = unsafeBitCast(window, to: AXUIElement.self)
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }
}
