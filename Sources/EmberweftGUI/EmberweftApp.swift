import SwiftUI
import AppKit
import EmberweftUI

/// Ensures the app — launched as a bare executable (no .app bundle) — registers as
/// a regular, activatable app and grabs keyboard focus. Without this the launch
/// shell (e.g. Claude Code) keeps keyboard focus and the window isn't fully
/// interactive (no keyboard events, no click-through).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The AppModel, wired by the main window's onAppear (the adaptor
    /// constructs the delegate before any model exists).
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quit guard (the lifecycle gap): ⌘Q/logout during a multi-hour render
    /// used to kill the in-flight chunk with no warning. Checkpoints keep the
    /// completed work, so confirm with an honest "Pause & Quit" — the export
    /// resumes from its checkpoint on the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model,
              QuitGuard.renderInProgress(export: model.exportManager, flock: model.flockModel)
        else { return .terminateNow }
        QuitGuard.confirmQuit(export: model.exportManager, flock: model.flockModel) { reply in
            NSApp.reply(toApplicationShouldTerminate: reply)
        }
        return .terminateLater
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
                .onAppear { appDelegate.model = model }
                .task { await model.loadBundle() }
                .task { await model.reloadDirectorySources() }
                .task { await model.rescanImported() }
        }
        .defaultSize(width: 1000, height: 680)
        // Menu bar (C2 remediation): every core command becomes reachable
        // from the menus (HIG: toolbar items must also be menu commands).
        // Commands can't reach view state, so view-owned flows (sheets,
        // popovers, focus, openWindow) are triggered via AppModel request
        // counters; flows with no view state (sentiment, add-to-collection)
        // act on the model directly.
        .commands {
            // File — content acquisition + output.
            CommandGroup(after: .newItem) {
                Button("Open Directory…") { model.openDirectoryRequest += 1 }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Import Genomes…") { model.importFilesRequest += 1 }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Export…") { model.exportRequest += 1 }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.selection.isEmpty)
                Button("New Collection…") { model.newCollectionRequest += 1 }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            // Genome — selection actions (the app-specific menu).
            CommandMenu("Genome") {
                Button("Play") { model.playSelectionRequest += 1 }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(model.selection.count != 1)
                Divider()
                Button("Like") { model.applySentiment(1, to: model.selection) }
                    .disabled(model.selection.isEmpty)
                Button("Neutral") { model.applySentiment(0, to: model.selection) }
                    .disabled(model.selection.isEmpty)
                Button("Dislike") { model.applySentiment(-1, to: model.selection) }
                    .disabled(model.selection.isEmpty)
                Divider()
                Menu("Add to Collection") {
                    Button("New Collection…") {
                        model.saveSelectionAsCollectionRequest += 1
                    }
                    ForEach(model.collectionsStore.collections) { c in
                        Button(c.name) {
                            let entries = model.selection
                                .sorted {
                                    GenomeCollectionAppOrder.key($0) < GenomeCollectionAppOrder.key($1)
                                }
                                .map(CollectionEntry.init)
                            _ = model.collectionsStore.addEntries(entries, to: c.id)
                        }
                    }
                }
                .disabled(model.selection.isEmpty)
            }
            // View — sidebar toggle + the Filter toolbar item as a command.
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") { model.toggleSidebarRequest += 1 }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Filter") { model.filterPopoverRequest += 1 }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            // Edit > Find — ⌘F focuses the library search field.
            CommandGroup(after: .textEditing) {
                Menu("Find") {
                    Button("Search") { model.findRequest += 1 }
                        .keyboardShortcut("f", modifiers: .command)
                }
            }
            // Help — replace the dead stock item with the shortcut cheat sheet.
            CommandGroup(replacing: .help) {
                Button("Emberweft Keyboard Shortcuts") { model.keyboardHelpRequest += 1 }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }

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
                        description: Text("This genome may have been removed or its folder rescanned. Close this window and pick another from the library.")
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
