#if DEBUG
import AppKit
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
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for tab in [AppState.Tab.today, .report] {
                state.tab = tab
                let view = PopoverView()
                    .environmentObject(state)
                    .background(VisualEffect())
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: appearance)
                hosting.frame.size = hosting.fittingSize

                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hosting
                window.appearance = NSAppearance(named: appearance)
                window.layoutIfNeeded()
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))

                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                let name = "\(tab == .today ? "hoje" : "relatorio")-\(appearance == .aqua ? "claro" : "escuro").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
                print("snapshot: \(directory.appendingPathComponent(name).path)")
            }
        }
        state.tab = .today

        for step in OnboardingView.Step.allCases {
            let view = OnboardingView(initialStep: step) {}.environmentObject(state)
            render(view, appearance: .aqua, to: directory.appendingPathComponent("boas-vindas-\(step.rawValue + 1).png"))
        }
        NSApp.terminate(nil)
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: \(url.path)")
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif
