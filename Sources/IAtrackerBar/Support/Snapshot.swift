#if DEBUG
import AppKit
import IAtrackerBarCore
import SwiftUI

/// `swift run IAtrackerBar --snapshot <pasta>`: renderiza o popover (Hoje/Relatório, claro/escuro)
/// em PNG e encerra. Só existe em builds de depuração, para revisar o visual sem clicar na barra.
@MainActor
enum Snapshot {
    static var outputDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func run(state: AppState, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shots: [(name: String, tab: AppState.Tab, range: ReportRange, appearance: NSAppearance.Name)] = [
            ("hoje-claro", .today, .week, .aqua),
            ("hoje-escuro", .today, .week, .darkAqua),
            ("relatorio-semana-claro", .report, .week, .aqua),
            ("relatorio-30dias-claro", .report, .thirtyDays, .aqua),
            ("relatorio-30dias-escuro", .report, .thirtyDays, .darkAqua),
        ]
        for shot in shots {
            state.tab = shot.tab
            state.reportRange = shot.range
            let view = PopoverView().environmentObject(state).background(VisualEffect())
            render(view, appearance: shot.appearance, to: directory.appendingPathComponent("\(shot.name).png"))
        }
        state.tab = .today
        state.reportRange = .week

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            render(MenuBarStrip(state: state), appearance: appearance,
                   to: directory.appendingPathComponent("barra-\(appearance == .aqua ? "claro" : "escuro").png"))
        }

        for step in OnboardingView.Step.allCases {
            let view = OnboardingView(initialStep: step) {}
                .environmentObject(state)
                .background(Color(nsColor: .windowBackgroundColor))
            render(view, appearance: .aqua, to: directory.appendingPathComponent("boas-vindas-\(step.rawValue + 1).png"))
        }
        NSApp.terminate(nil)
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: appearance)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: \(url.path)")
    }
}

/// Faixa que imita a barra de menus, com o item do app ao lado do relógio.
private struct MenuBarStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            MenuBarLabel(state: state)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            Image(systemName: "wifi")
            Image(systemName: "battery.75")
            Text("Seg 5 out  14:32")
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .frame(width: 520, height: 30)
        .background(VisualEffect(material: .menu))
    }
}

private struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif
