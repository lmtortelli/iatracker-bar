import AppKit
import SwiftUI

@main
struct IAtrackerBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sem ícone no Dock mesmo quando rodado fora do .app (`swift run`).
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        if let directory = Snapshot.outputDirectory {
            Task { @MainActor in
                Snapshot.run(state: AppState.bootstrap(demo: true), to: directory)
            }
            return
        }
        #endif

        Task { @MainActor in
            guard !SingleInstance.handOffIfAlreadyRunning() else { return }
            SingleInstance.terminateLegacyApp()
            let state = AppState.shared
            state.startCollecting()
            if !state.isDemo { OnboardingWindow.showIfNeeded(state: state) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.monitor?.shutdown()
        }
    }
}
