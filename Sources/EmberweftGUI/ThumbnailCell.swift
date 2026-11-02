import SwiftUI
import EmberweftUI
import FlameKit

/// One grid card: poster thumbnail + category pill + a hover-revealed sentiment
/// bar (compact badge when marked) + a hover/selected tick. Interaction (open /
/// select) is handled by the wrapping `cell()` in LibraryView; this view is
/// display + the in-cell controls (sentiment bar, selection tick).
struct ThumbnailCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: LibraryEntry
    let selected: Bool
    /// Thumbnail frame. `.grid` (default) is the 16:9 card used by the library
    /// grid — FLEXIBLE: it fills the adaptive column's width at a fixed 16:9
    /// aspect, so the Density control truly resizes cards (the old fixed
    /// 176×99 ignored the column proposal entirely). `.list` is the fixed
    /// compact row thumb used by the collection reorder list.
    var size: Size = .grid
    /// Whether to render the display-name caption beneath the thumbnail. The
    /// collection reorder list shows the name to the side of the thumb, so it
    /// passes `false` to avoid a duplicate.
    var showsName: Bool = true
    /// Keyboard focus (C1 grid navigation): draws the focus ring and reveals
    /// the sentiment bar exactly like hover, so keyboard-only users get the
    /// same affordances pointer users get.
    var isFocused: Bool = false

    enum Size { case grid, list
        /// Fixed frame for `.list`; `.grid` is column-driven (aspectRatio +
        /// maxWidth .infinity in `body`) and returns nil here.
        var fixedFrame: CGSize? {
            switch self {
            case .grid: return nil
            case .list: return CGSize(width: 80, height: 45)   // 16:9, compact
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
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(width: size.fixedFrame?.width,
                       height: size.fixedFrame?.height)
                .frame(maxWidth: size.fixedFrame == nil ? .infinity : nil)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Selection ring (reinforces the tick).
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                // Keyboard-focus ring (C1): sits OUTSIDE the selection ring so
                // a selected card reads as both (double ring), and a focused
                // unselected card still shows where keyboard input lands.
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                            .padding(-3)
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
                    // Revealed by hover OR keyboard focus (C1): hover-only
                    // gating made rating pointer-only.
                    if isHovered || isFocused {
                        SentimentBar(entry: entry)
                            .padding(4)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isHovered && !isFocused { SentimentBadge(entry: entry).padding(6) }
                }
            if showsName {
                Text(entry.displayName)
                    .font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: isHovered)
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: isFocused)
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
        .opacity(selected ? 1 : (tickVisible ? 0.9 : 0))
        // Invisible controls must be inert: opacity alone removes the tick
        // from neither the hit-test tree nor the accessibility tree, so the
        // hidden button used to swallow top-right clicks and could surface a
        // phantom "Select" element. Gate both on the visibility the opacity
        // already uses.
        .allowsHitTesting(tickVisible)
        .accessibilityHidden(!tickVisible)
        .accessibilityLabel(selected ? "Deselect" : "Select")
    }

    /// Whether the tick is actually shown (selected, hovered, or focused).
    private var tickVisible: Bool { selected || isHovered || isFocused }

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
                    .help("Couldn't render this genome — its file is unreadable or damaged")
            }
        }
    }

    private func load() async {
        // First line: this cell is onscreen and its thumb is pending — the
        // toolbar bar's denominator (see AppModel.thumbAppearedCount).
        model.markThumbAppeared(for: entry)
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
