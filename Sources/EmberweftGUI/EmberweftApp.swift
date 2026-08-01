import SwiftUI
import AppKit
import EmberweftUI

/// Ensures the app — launched as a bare executable (no .app bundle) — registers as
/// a regular, activatable app and grabs keyboard focus. Without this the launch
/// shell (e.g. Claude Code) keeps keyboard focus and the window isn't fully
/// interactive (no keyboard events, no click-through).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct EmberweftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Emberweft") {
            LibraryView()
                .environment(model)
                .task { await model.loadBundle() }
                .task { await model.reloadDirectoryIfSet() }
                .task { await model.rescanImported() }
        }
        .defaultSize(width: 1000, height: 680)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
