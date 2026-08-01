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
                .task { await model.reloadDirectorySources() }
                .task { await model.rescanImported() }
        }
        .defaultSize(width: 1000, height: 680)

        // Non-modal playback window (B9) — one per genome, value-driven by
        // `PlaybackRoute` (identity = stored fields, so clicking a card that's
        // already open focuses its window instead of stacking a sheet). Replaces
        // the blocking `.sheet` in `LibraryView`; users can browse/rate while a
        // loop plays. The window re-resolves the live `LibraryEntry` on open so a
        // directory rescan / removal shows a clean placeholder, not a stale flame.
        WindowGroup("Playback", for: PlaybackRoute.self) { $route in
            if let route {
                if let entry = route.resolve(model: model) {
                    PlaybackWindow(entry: entry)
                        .environment(model)
                } else {
                    ContentUnavailableView(
                        "Genome no longer available",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("This flame may have been removed or its folder rescanned. Close this window and pick another from the library.")
                    )
                    .frame(minWidth: 480, minHeight: 320)
                }
            }
        }
        .defaultSize(width: 800, height: 600)

        // Non-modal sequence-playback window — one per collection, value-driven
        // by `CollectionPlaybackRoute` (identity = collection id). The window
        // re-resolves the live collection + genomes on open, so a deleted/
        // edited collection shows a clean placeholder. Plays the collection's
        // resolved genomes in order via the multi-genome `PlaybackDispatcher`
        // (loop + transition segments). Does NOT touch the single-genome
        // `Playback` WindowGroup above.
        WindowGroup("Collection Playback", for: CollectionPlaybackRoute.self) { $route in
            if let route {
                CollectionPlaybackWindow(collectionId: route.id)
                    .environment(model)
            }
        }
        .defaultSize(width: 800, height: 600)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
