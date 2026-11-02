import AppKit
import UserNotifications
import EmberweftUI

/// System integration for long renders (the notifications gap): a multi-hour
/// export or flock generate finishing while the app is backgrounded previously
/// gave NO signal at all (only the in-window banner, invisible in another app).
///
/// - **User notifications** on terminal export/flock states, gated on
///   `NSApp.isActive == false` (the in-window banner stays the frontmost path).
///   Authorization is requested as PROVISIONAL at first use — no upfront
///   prompt; notifications arrive quietly in Notification Center until the
///   user promotes them (notifications.md: consent first, interrupt least).
/// - **Dock badge** mirrors overall progress ("42%") during a run, updated by
///   a 1 Hz timer AppModel runs only while a render is live.
@MainActor
enum CompletionNotifications {

    /// Posted once per launch; the provisional grant covers the app silently.
    @MainActor private static let authRequested = AuthFlag()
    private final class AuthFlag {
        var requested = false
    }

    static func requestAuthorizationIfNeeded() {
        guard !authRequested.requested else { return }
        authRequested.requested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.provisional]) { _, _ in }
    }

    /// Fire a completion/pause notification IF the app is backgrounded. The
    /// caller supplies plain title/body; cancel-state is intentionally not
    /// notified (user-initiated, already known).
    static func post(title: String, body: String) {
        guard !NSApp.isActive else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Deterministic id per content so a re-fired identical event coalesces.
        let request = UNNotificationRequest(
            identifier: "emberweft-\(title)-\(body.hashValue)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Map an export state transition to its notification, or nil for states
    /// that don't warrant one (cancel is user-initiated; in-flight states are
    /// the badge's job). A PAUSE is attention-needed (disk full, Metal gone).
    static func exportNotification(for state: ExportState) -> (title: String, body: String)? {
        switch state {
        case .completed(let url):
            return ("Export finished", url.lastPathComponent)
        case .failed(let message):
            return ("Export failed", message)
        case .paused(_, _, let reason):
            return ("Export paused", reason ?? "The export was paused.")
        case .idle, .running, .pausing, .cancelling, .cancelled:
            return nil
        }
    }

    // MARK: - Dock badge

    /// Overall render progress for the dock badge, or nil when idle (badge
    /// cleared). Export fraction wins; a flock run reports its unit fraction.
    static func overallProgress(export: ExportManager?, flock: FlockModel?) -> Double? {
        if let em = export, em.state.isInFlight {
            let snap = em.snapshot
            if snap.totalJobs > 1 {
                return (Double(snap.jobIndex) + snap.fraction) / Double(snap.totalJobs)
            }
            return snap.fraction
        }
        if let fm = flock, fm.hasActiveRun,
           let fraction = fm.overallRunFraction {
            return fraction
        }
        return nil
    }

    /// Refresh the dock badge from the given fraction (nil clears it).
    static func updateDockBadge(fraction: Double?) {
        let tile = NSApplication.shared.dockTile
        if let f = fraction {
            tile.badgeLabel = "\(Int((f * 100).rounded()))%"
        } else {
            tile.badgeLabel = nil
        }
    }
}

/// Quit guard (the lifecycle gap): ⌘Q or logout mid-render used to kill the
/// in-flight chunk with zero warning. Exports checkpoint and flock keeps
/// completed units, so the honest message is "pause + resume next launch".
@MainActor
enum QuitGuard {

    /// True when any long render is live (export running/pausing/paused, or a
    /// flock generate/stitch in flight). Paused counts: quitting discards the
    /// paused state's in-flight chunk too (resume re-renders it).
    static func renderInProgress(export: ExportManager?, flock: FlockModel?) -> Bool {
        if let em = export, em.state.isInFlight { return true }
        if let fm = flock, fm.hasActiveRun { return true }
        return false
    }

    /// Present the confirm alert; invokes `reply` with the user's choice on
    /// the main actor. Two options only — "Pause & Quit" (checkpoints keep
    /// completed work; the export resumes next launch) and Cancel.
    static func confirmQuit(export: ExportManager?, flock: FlockModel?,
                            reply: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "A render is in progress"
        alert.informativeText = "Quitting now stops the in-flight frame; completed work is kept. " +
            "Exports resume from their checkpoint the next time you open Emberweft, and Flock " +
            "keeps everything already generated."
        alert.addButton(withTitle: "Pause & Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal()
        reply(response == .alertFirstButtonReturn)
    }
}
