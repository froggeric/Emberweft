import SwiftUI
import EmberweftUI

/// Edits one genome's metadata (tags / rating / favorite / notes) in a sheet.
/// Bound to the shared `MetadataStore`, which persists on change.
struct MetadataEditorView: View {
    let entry: LibraryEntry
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft: GenomeMetadata = .empty
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(entry.displayName).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }

            Toggle("Favorite", isOn: $draft.favorite)

            VStack(alignment: .leading, spacing: 6) {
                Text("Rating").font(.subheadline)
                HStack(spacing: 8) {
                    ForEach(0...5, id: \.self) { n in
                        Button {
                            draft.rating = (draft.rating == n && n > 0) ? n - 1 : n
                        } label: {
                            Image(systemName: n <= draft.rating ? "star.fill" : "star")
                                .foregroundStyle(.yellow)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(n) stars")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tags").font(.subheadline)
                HStack {
                    TextField("Add tag", text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTag)
                    Button("Add", action: addTag)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if draft.tags.isEmpty {
                    Text("No tags").foregroundStyle(.secondary).font(.caption)
                } else {
                    TagFlowLayout(spacing: 6) {
                        ForEach(draft.tags, id: \.self) { tag in
                            HStack(spacing: 2) {
                                Text(tag)
                                Button { removeTag(tag) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove tag \(tag)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.subheadline)
                TextEditor(text: $draft.notes)
                    .frame(minHeight: 60)
                    .border(.quaternary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 380)
        .onAppear { draft = model.metadataStore.metadata(for: entry) }
        .onChange(of: draft) { _, newValue in
            model.metadataStore.set(newValue, for: entry)   // persists (coalesced)
        }
        .accessibilityLabel("Metadata editor for \(entry.displayName)")
    }

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.metadataStore.update(for: entry) { $0.tags.append(t) }
        draft = model.metadataStore.metadata(for: entry)
        newTag = ""
    }

    private func removeTag(_ tag: String) {
        model.metadataStore.update(for: entry) { md in
            md.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        draft = model.metadataStore.metadata(for: entry)
    }
}

/// A minimal wrapping flow layout for tag chips (custom `Layout` — macOS 13+;
/// deployment is macOS 26, so always available).
private struct TagFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxWidth && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxWidth.isInfinite ? x : maxWidth, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
