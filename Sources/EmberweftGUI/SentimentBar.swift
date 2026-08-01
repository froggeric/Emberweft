import SwiftUI
import EmberweftUI

/// Tri-state sentiment control (−1 dislike / 0 neutral / +1 like), direct-set.
/// Redundant color + glyph + left→right mapping onto the negative→positive
/// spectrum (preattentive; color-blind safe). Used both as a full-width hover bar
/// on cards and (compact) in the playback transport.
struct SentimentBar: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry

    private var sentiment: Int { model.metadataStore.metadata(for: entry).sentiment }

    var body: some View {
        HStack(spacing: 0) {
            segment(-1, "hand.thumbsdown", .red, "Dislike")
            segment(0, "circle", .secondary, "Neutral")
            segment(1, "hand.thumbsup", .green, "Like")
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(.ultraThinMaterial.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
    }

    private func segment(_ value: Int, _ icon: String, _ tint: Color, _ label: String) -> some View {
        let active = sentiment == value
        return Button {
            model.metadataStore.setSentiment(value, for: entry)
        } label: {
            Image(systemName: active ? "\(icon).fill" : icon)
                .foregroundStyle(active ? tint : Color.secondary.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .symbolEffect(.bounce, value: active)
        .accessibilityLabel(label)
    }
}

/// Compact always-on badge for *marked* (non-neutral) cells — preattentive scan
/// without hover. Hidden when neutral (the common case keeps the grid calm).
struct SentimentBadge: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    private var sentiment: Int { model.metadataStore.metadata(for: entry).sentiment }

    var body: some View {
        if sentiment != 0 {
            let liked = sentiment == 1
            Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                .foregroundStyle(liked ? Color.green : Color.red)
                .font(.caption)
                .padding(5)
                .background(.ultraThinMaterial, in: Circle())
                .accessibilityLabel(liked ? "Liked" : "Disliked")
        }
    }
}

/// Bottom-floating selection bar with bulk actions (Mail/Files pattern). Appears
/// the instant a selection exists; carries the count + the payoff.
struct SelectionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Text("\(model.selection.count) selected").font(.body).monospacedDigit()
            Divider().frame(height: 18)
            Button { model.applySentiment(1, to: model.selection) } label: {
                Label("Like", systemImage: "hand.thumbsup")
            }
            Button { model.applySentiment(-1, to: model.selection) } label: {
                Label("Dislike", systemImage: "hand.thumbsdown")
            }
            Divider().frame(height: 18)
            Button { model.clearSelection() } label: {
                Label("Clear", systemImage: "xmark").labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 6, y: 2)
    }
}
