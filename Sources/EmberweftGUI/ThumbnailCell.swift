import SwiftUI
import EmberweftUI
import FlameKit

/// One grid cell: placeholder-first async thumbnail + a category pill (rank OR
/// heuristic facet) + a tri-state sentiment control + a selection border.
/// Interaction (select / play) is handled by the wrapping `cell()` in LibraryView;
/// this view is display + the in-cell sentiment toggle.
struct ThumbnailCell: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    let selected: Bool

    enum ThumbState: Equatable { case placeholder, ready(NSImage), failed }
    @State private var state: ThumbState = .placeholder

    private var sentiment: Int { model.metadataStore.metadata(for: entry).sentiment }
    private var category: String? { entry.rank?.category ?? model.facets.facet(for: entry)?.category }

    var body: some View {
        VStack(spacing: 6) {
            content
                .frame(width: 176, height: 99)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    if let cat = category {
                        Text(cat.capitalized)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) { sentimentButton }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
            Text(entry.displayName)
                .font(.caption).lineLimit(1).foregroundStyle(.secondary)
        }
        .task(id: entry.id, priority: .utility) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .placeholder: ProgressView()
        case .ready(let img): Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        case .failed:
            ZStack {
                Color.black
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    /// Tri-state sentiment: −1 dislike / 0 neutral / +1 like. Tap cycles.
    private var sentimentButton: some View {
        Button {
            let next: Int = sentiment == 0 ? 1 : (sentiment == 1 ? -1 : 0)
            model.metadataStore.setSentiment(next, for: entry)
        } label: {
            Image(systemName: sentimentIcon)
                .foregroundStyle(sentimentColor)
                .font(.caption)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sentimentLabel)
        .accessibilityHint("Cycles like, dislike, neutral.")
    }

    private var sentimentIcon: String {
        switch sentiment { case 1: "hand.thumbsup.fill"; case -1: "hand.thumbsdown.fill"; default: "circle" }
    }
    private var sentimentColor: Color {
        switch sentiment { case 1: .green; case -1: .red; default: .white.opacity(0.7) }
    }
    private var sentimentLabel: String {
        switch sentiment { case 1: "Liked"; case -1: "Disliked"; default: "Neutral" }
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
