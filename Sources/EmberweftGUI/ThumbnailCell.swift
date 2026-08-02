import SwiftUI
import EmberweftUI
import FlameKit

/// One grid card: poster thumbnail + category pill + a hover-revealed sentiment
/// bar (compact badge when marked) + a hover/selected tick. Interaction (open /
/// select) is handled by the wrapping `cell()` in LibraryView; this view is
/// display + the in-cell controls (sentiment bar, selection tick).
struct ThumbnailCell: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    let selected: Bool
    /// Thumbnail frame. `.grid` (default) is the 16:9 card used by the library
    /// grid; `.list` is the compact row thumb used by the collection reorder
    /// list. Defaults preserve the existing grid call sites.
    var size: Size = .grid
    /// Whether to render the display-name caption beneath the thumbnail. The
    /// collection reorder list shows the name to the side of the thumb, so it
    /// passes `false` to avoid a duplicate.
    var showsName: Bool = true

    enum Size { case grid, list
        var frame: CGSize {
            switch self {
            case .grid: return CGSize(width: 176, height: 99)   // 16:9
            case .list: return CGSize(width: 80, height: 45)    // 16:9, compact
            }
        }
    }

    enum ThumbState: Equatable { case placeholder, ready(NSImage), failed }
    @State private var state: ThumbState = .placeholder
    @State private var isHovered = false

    private var category: String? { entry.rank?.category ?? model.facets.facet(for: entry)?.category }

    var body: some View {
        VStack(spacing: 6) {
            content
                .frame(width: size.frame.width, height: size.frame.height)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Selection ring (reinforces the tick).
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let cat = category {
                        Text(cat.capitalized)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) { tick }
                .overlay(alignment: .bottom) {
                    if isHovered {
                        SentimentBar(entry: entry)
                            .padding(4)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isHovered { SentimentBadge(entry: entry).padding(6) }
                }
            if showsName {
                Text(entry.displayName)
                    .font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.12), value: isHovered)
        .task(id: entry.id, priority: .utility) { await load() }
    }

    /// Selection tick (top-right): visible when selected or hovered.
    private var tick: some View {
        Button { model.toggleInSelection(entry) } label: {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .font(.title3)
                .padding(6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(selected ? 1 : (isHovered ? 0.9 : 0))
        .accessibilityLabel(selected ? "Selected" : "Select")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .placeholder:
            RoundedRectangle(cornerRadius: 8).fill(.quaternary).redacted(reason: .placeholder)
        case .ready(let img):
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        case .failed:
            ZStack {
                Color.black
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.white.opacity(0.4))
                    .help("Degenerate / unreadable genome")
            }
        }
    }

    private func load() async {
        guard let flame = try? await model.libraryIndex.loadGenome(for: entry) else {
            state = .failed
            model.markThumbResolved(for: entry)
            return
        }
        model.facets.putIfAbsent(for: entry, flame: flame)
        let outcome = await model.thumbnailService.thumbnail(
            for: entry, flame: flame,
            renderParams: model.prefs.thumbnailRenderParams(),
            displayWidth: model.prefs.thumbnailWidth,
            displayHeight: model.prefs.thumbnailHeight,
            backend: model.prefs.thumbnailBackend)
        switch outcome {
        case .image(let rgba):
            state = .ready(rgba.toNSImage() ?? NSImage())
            model.facets.refine(for: entry, image: rgba)
            model.markThumbResolved(for: entry)
        case .degenerate:
            model.hideEntry(for: entry)
        case .failed:
            state = .failed
            model.markThumbResolved(for: entry)
        }
    }
}
