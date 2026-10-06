import AppKit
import SwiftUI

/// Conteúdo da janela do `MenuBarExtra` (largura 360).
struct PopoverView: View {
    @EnvironmentObject private var state: AppState
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Visão", selection: $state.tab) {
                Text("Hoje").tag(AppState.Tab.today)
                Text("Relatório").tag(AppState.Tab.report)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))

            switch state.tab {
            case .today:
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    TodayView(now: context.date)
                }
            case .report:
                TimelineView(.everyMinute) { context in
                    ReportView(now: context.date)
                }
            }

            footer
        }
        .frame(width: 360)
        // A janela do MenuBarExtra assume a altura proposta pelo conteúdo: sem isto ela pode
        // crescer até a altura da tela e o conteúdo fica centralizado, longe da barra de menus.
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PopoverHeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(PopoverHeightKey.self) { contentHeight = $0 }
        .background(PopoverWindowStyler(cornerRadius: Theme.popoverRadius, contentHeight: contentHeight))
        .font(.system(size: 12))
        .onAppear { state.popoverOpened() }
        .onDisappear { state.popoverClosed() }
        .background(quitShortcut)
    }

    private var footer: some View {
        HStack {
            Button(state.paused ? "▶ Retomar detecção" : "❙❙ Pausar detecção") {
                state.togglePause()
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Preferências…") {
                PreferencesWindow.show(state: state)
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.secondary)
            .keyboardShortcut(",", modifiers: .command)

            Text("·").foregroundColor(Theme.secondary.opacity(0.6))

            Button("Sair") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundColor(Theme.secondary)
                .help("Encerrar o IAtracker-bar (⌘Q)")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .topSeparator()
    }

    /// App sem Dock nem menu: ⌘Q dentro do popover encerra.
    private var quitShortcut: some View {
        Button("Sair") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Arredonda a janela do `MenuBarExtra`: o padrão do sistema tem cantos quase retos.
/// Aplica o raio (curva contínua) na view de conteúdo e nas superiores — o fundo de vidro do
/// sistema fica recortado junto — e recalcula a sombra a cada mudança de tamanho.
struct PopoverWindowStyler: NSViewRepresentable {
    let cornerRadius: CGFloat
    /// Altura do conteúdo: a janela do `MenuBarExtra` cresce sozinha, mas não encolhe
    /// (ex.: ao recolher o histórico), então ajustamos à mão, mantendo o topo preso à barra.
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = StylerView()
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? StylerView)?.fit(contentHeight: contentHeight)
    }

    final class StylerView: NSView {
        var cornerRadius: CGFloat = 16
        private var resizeObserver: NSObjectProtocol?
        private var pendingHeight: CGFloat = 0

        func fit(contentHeight: CGFloat) {
            pendingHeight = contentHeight
            // Fora do ciclo de atualização do SwiftUI, para não redimensionar no meio do layout.
            DispatchQueue.main.async { [weak self] in self?.applyHeight() }
        }

        private func applyHeight() {
            guard let window, pendingHeight > 1 else { return }
            var frame = window.frame
            let content = window.contentRect(forFrameRect: frame)
            let delta = pendingHeight.rounded() - content.height
            guard abs(delta) >= 1 else { return }
            frame.size.height += delta
            frame.origin.y -= delta // mantém a borda de cima no lugar
            window.setFrame(frame, display: true, animate: false)
            window.invalidateShadow()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                self?.apply(to: window)
                self?.applyHeight()
            }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak window] _ in window?.invalidateShadow() }
        }

        private func apply(to window: NSWindow) {
            window.isOpaque = false
            window.backgroundColor = .clear
            var view: NSView? = window.contentView
            while let current = view {
                current.wantsLayer = true
                current.layer?.cornerRadius = cornerRadius
                current.layer?.cornerCurve = .continuous
                current.layer?.masksToBounds = true
                view = current.superview
            }
            window.invalidateShadow()
        }

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }
    }
}

private struct PopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
