import Quartz

/// macOS Quick Look for Flock Browse artifacts (double-click / context-menu
/// Preview / VoiceOver action). SwiftUI's `.quickLookPreview` modifier is
/// iOS-only — on macOS the shared `QLPreviewPanel` needs a retained data
/// source object, which is exactly what this is.
///
/// One item at a time: the grid presents a single artifact URL (the panel's
/// own navigation arrows are disabled by returning count == 1). NSURL bridges
/// to `QLPreviewItem` natively, so no custom item type is needed.
@MainActor
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()

    private var url: URL?

    private override init() {
        super.init()
    }

    /// Show (or re-target) the panel on one file. Safe to call repeatedly.
    func present(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        MainActor.assumeIsolated {
            // NSURL conforms to QLPreviewItem (previewItemURL + auto title).
            (url as NSURL?) ?? NSURL()
        }
    }
}
