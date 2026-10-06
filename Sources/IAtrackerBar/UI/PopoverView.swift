import AppKit
import SwiftUI

/// Conteúdo da janela do `MenuBarExtra` (largura 360).
struct PopoverView: View {
    @EnvironmentObject private var state: AppState

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
        .font(.system(size: 12))
        .onAppear { state.popoverOpened() }
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
