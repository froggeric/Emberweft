import SwiftUI
import EmberweftUI
import FlameExport

/// Non-blocking export-progress banner (spec §4.7 / G8). Observes
/// `model.exportManager` and renders a compact card for every non-`.idle`
/// state:
/// - `.running` / `.cancelling`: a determinate `ProgressView` + phase / frame /
///   FPS / elapsed line (+ batch `jobIndex / totalJobs` when `totalJobs > 1`)
///   and a Cancel button.
/// - `.completed(url)`: "Saved to <name>" + Show in Finder + Dismiss.
/// - `.failed(message)`: the message + Dismiss.
/// - `.cancelled`: "Cancelled." + Dismiss.
///
/// Returns `EmptyView` when `state == .idle`, so it disappears after Dismiss
/// (`exportManager.reset()`).
///
/// Mounted in all three window types in M6-G.8 (the main `LibraryView` window is
/// NOT always open — spec §4.7 / D-G9 — and an export is most often started from
/// a playback window). Each instance is a thin overlay on the shared
/// `ExportManager` held by `AppModel` (cheap: one `@Observable` read per snapshot;
/// `ExportManager` survives sheet/window teardown — G9).
///
/// Cancel uses `await exportManager.cancel()` (cooperative — the VM/coordinator
/// handle the partial cleanup; do NOT touch the coordinator directly). The
/// degraded all-windows-closed case is documented in spec §4.7 (the export
/// continues on `AppModel.exportManager`; there is no visible Cancel until a
/// window reopens).
struct ExportProgressSurface: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.exportManager.state
        if state != .idle {
            content(for: state)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 6, y: 2)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func content(for state: ExportState) -> some View {
        switch state {
        case .idle:
            EmptyView()   // unreachable (body guards .idle), but exhaustive
        case .running, .cancelling:
            runningContent
        case .pausing:
            // M6.1: a pause has been requested; the run loop will surface
            // `.paused` at the next chunk boundary. Render the running card so
            // Cancel stays reachable; `runningContent` disables the Pause button
            // and flips its label to "Pausing…" while in this state.
            runningContent
        case .paused(let out, _, let reason):
            // M6.1: the export is suspended with a checkpoint on disk. Resume
            // continues from the checkpoint; Discard deletes it + chunks.
            pausedContent(out: out, reason: reason)
        case .completed(let url):
            completedContent(url: url)
        case .failed(let message):
            terminalContent(message: message, banner: "Export failed")
        case .cancelled:
            terminalContent(message: "Cancelled.", banner: "Export cancelled", isError: false)
        }
    }

    // MARK: - Paused (M6.1 — spec §6.1)

    private func pausedContent(out: URL, reason: String?) -> some View {
        let em = model.exportManager
        let snap = em.snapshot
        let title = reason ?? "Paused"
        return HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) — frame \(snap.currentFrame) of \(snap.totalFrames)")
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(out.lastPathComponent).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Resume") { Task { await em.resume() } }
                .help("Continue from the last checkpoint.")
            Button("Discard") { em.discardPaused() }
                .help("Delete the checkpoint and completed chunks, return to idle.")
        }
    }

    // MARK: - Running / pausing / cancelling

    private var runningContent: some View {
        let em = model.exportManager
        let snap = em.snapshot
        let isCancelling = em.state == .cancelling
        let isPausing = em.state == .pausing
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ProgressView(value: snap.fraction)
                    .progressViewStyle(.linear)
                    .help("Overall progress")
                // Pause: shown only for pausable (`.runResumable`) exports —
                // hidden for batch/`.runJob` (no checkpoint ⇒ nothing to resume).
                // Disabled + "Pausing…" once a pause is in flight (the run loop
                // surfaces `.paused` at the next chunk boundary).
                if em.isPausable {
                    Button(isPausing ? "Pausing…" : "Pause") {
                        Task { await em.pause() }
                    }
                    .disabled(isPausing)
                    .help("Finish the in-flight frame, keep completed work, and stop. Resume later.")
                }
                Button(isCancelling ? "Cancelling…" : "Cancel") {
                    Task { await em.cancel() }
                }
                .disabled(isCancelling)
                .help("Finish the in-flight frame, then stop and discard the partial file.")
            }
            runningStatusLabel(snap: snap)
            if let notice = em.skipNotice {
                Text(notice)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One compact status line: phase — frame / total (fps, elapsed, ETA) [batch
    /// job]. The ETA token is appended after elapsed: "estimating…" during
    /// cold-start (fewer than `coldStartFloor` rendering samples), "~Xh Ym
    /// remaining" once the EMA converges, or "Finalizing…" on non-rendering
    /// phases (encoding/concatenating/finalizing — the render ETA is frozen).
    /// `sourceLabel` (display name / count) is shown on its own line when present
    /// and there's batch context (otherwise the phase line already fits).
    @ViewBuilder
    private func runningStatusLabel(snap: ExportProgressSnapshot) -> some View {
        let line = HStack(spacing: 8) {
            Text(phaseLabel(snap.phase))
            Text("frame \(snap.currentFrame) / \(snap.totalFrames)").monospacedDigit()
            Text(String(format: "%.1f fps", snap.renderFPS)).monospacedDigit()
            Text("\(elapsedLabel(snap.elapsed))")
            Text(etaToken(snap))
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if snap.totalJobs > 1 {
            VStack(alignment: .leading, spacing: 2) {
                line
                if !model.exportManager.sourceLabel.isEmpty {
                    HStack(spacing: 8) {
                        Text(model.exportManager.sourceLabel)
                            .lineLimit(1).truncationMode(.middle)
                        Text("job \(snap.jobIndex + 1) of \(snap.totalJobs)").monospacedDigit()
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("job \(snap.jobIndex + 1) of \(snap.totalJobs)")
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        } else {
            line
        }
    }

    // MARK: - Terminal states

    private func completedContent(url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved to \(url.lastPathComponent)")
                    .lineLimit(1).truncationMode(.middle)
                let parent = url.deletingLastPathComponent().path
                if !parent.isEmpty {
                    Text(parent).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Dismiss") { model.exportManager.reset() }
        }
    }

    /// Shared layout for `.failed` / `.cancelled`. `banner` is the leading title;
    /// `message` is the detail (the failure reason / "Cancelled."). `isError`
    /// tints the leading glyph red vs a neutral check for cancel.
    private func terminalContent(message: String, banner: String, isError: Bool = true) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner).font(.caption).foregroundStyle(.secondary)
                Text(message)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Dismiss") { model.exportManager.reset() }
        }
    }

    // MARK: - Formatting helpers

    /// Capitalized single-word phase for display (`.rendering` → "Rendering").
    private func phaseLabel(_ phase: ExportProgress.Phase) -> String {
        switch phase {
        case .rendering:     "Rendering"
        case .encoding:      "Encoding"
        case .concatenating: "Concatenating"
        case .finalizing:    "Finalizing"
        }
    }

    /// Whole-second elapsed time ("42 s"); avoids a twitching sub-second digit
    /// (mirrors the FPS-meter publish-throttle philosophy, CLAUDE.md v0.3.1).
    /// Delegates to the shared `ProgressFormatting` (v0.5.9 — one formatter
    /// app-wide, not a private fork).
    private func elapsedLabel(_ elapsed: TimeInterval) -> String {
        ProgressFormatting.elapsedLabel(elapsed)
    }

    /// The ETA token appended after elapsed on the status line (v0.5.0). On
    /// non-rendering phases the render ETA is frozen and the token reads
    /// "Finalizing…" (catch-all for encoding/concatenating/finalizing). During
    /// rendering: "estimating…" until the EMA warms past `coldStartFloor`, then a
    /// smoothed "~Xh Ym remaining" derived from the per-frame EMA (the shared
    /// `ProgressFormatting` formatter).
    private func etaToken(_ snap: ExportProgressSnapshot) -> String {
        if snap.phase != .rendering { return "Finalizing…" }
        return ProgressFormatting.etaToken(snap.etaSeconds)
    }
}
