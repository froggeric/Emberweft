import SwiftUI
import EmberweftUI
import FlameKit

/// One grid cell: placeholder-first async thumbnail load. Degenerate (all-black
/// / NaN-camera) genomes are excluded from the grid entirely (hidden), not badged.
struct ThumbnailCell: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry

    enum ThumbState: Equatable {
        case placeholder
        case ready(NSImage)
        case failed
    }

    @State private var state: ThumbState = .placeholder

    var body: some View {
        VStack(spacing: 6) {
            content
                .frame(width: 176, height: 99)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    if let rank = entry.rank {
                        Text(rank.category.capitalized)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        model.metadataStore.update(for: entry) { $0.favorite.toggle() }
                    } label: {
                        Image(systemName: model.metadataStore.metadata(for: entry).favorite
                              ? "heart.fill" : "heart")
                            .foregroundStyle(model.metadataStore.metadata(for: entry).favorite
                                             ? .pink : .white.opacity(0.85))
                            .font(.caption)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.metadataStore.metadata(for: entry).favorite
                                        ? "Unfavorite" : "Favorite")
                    .accessibilityHint("Toggles favorite.")
                }
            Text(entry.displayName)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .task(id: entry.id, priority: .utility) {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .placeholder:
            ProgressView()
        case .ready(let img):
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        case .failed:
            ZStack {
                Color.black
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func load() async {
        guard let flame = try? await model.libraryIndex.loadGenome(for: entry) else {
            state = .failed
            model.markThumbResolved(for: entry)
            return
        }
        // Palette facet for filtering (genome already parsed + cached; cheap, no
        // extra parse, no overwrite).
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
            // Refine the palette hue from the actual rendered pixels (matches what
            // the user sees; the palette mean is only a proxy).
            model.facets.refine(for: entry, image: rgba)
            model.markThumbResolved(for: entry)
        case .degenerate:
            // Exclude degenerate genomes from the grid entirely.
            model.hideEntry(for: entry)
        case .failed:
            state = .failed
            model.markThumbResolved(for: entry)
        }
    }
}

