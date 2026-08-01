import SwiftUI
import AppKit
import EmberweftUI

@main
struct EmberweftApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Emberweft") {
            LibraryView()
                .environment(model)
                .task { await model.loadBundle() }
                .task { await model.reloadDirectoryIfSet() }
                .task { await model.rescanImported() }
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1000, height: 680)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
