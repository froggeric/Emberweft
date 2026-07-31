import SwiftUI
import UniformTypeIdentifiers
import EmberweftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedEntry: LibraryEntry?
    @State private var openImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    bundleSection
                    directorySection
                }
                .padding(20)
            }
            .navigationTitle("Emberweft Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open Directory…") { openImporter = true }
                }
                if let progress = thumbProgress, progress < 1.0 {
                    ToolbarItem(placement: .navigation) {
                        HStack(spacing: 6) {
                            ProgressView(value: progress)
                                .frame(width: 120)
                            Text("\(model.renderedThumbIDs.count)/\(model.thumbTotal)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .fileImporter(isPresented: $openImporter, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    Task { await model.openDirectory(url) }
                case .failure:
                    break
                }
            }
            .sheet(item: $selectedEntry) { entry in
                PlaybackWindow(entry: entry)
                    .environment(model)
            }
        }
    }

    @ViewBuilder
    private var bundleSection: some View {
        section(title: "Curated", state: model.bundleLoadState)
    }

    @ViewBuilder
    private var directorySection: some View {
        if let dir = model.prefs.defaultLibraryDir {
            section(title: "Directory — \(dir.lastPathComponent)", state: model.dirLoadState)
        } else {
            switch model.dirLoadState {
            case .ready, .empty, .failed:
                EmptyView()
            case .loading:
                ProgressView().frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func section(title: String, state: LoadState) -> some View {
        switch state {
        case .loading:
            ProgressView("Loading \(title)…")
                .frame(maxWidth: .infinity, alignment: .leading)
        case .empty:
            Text("No genomes in \(title).")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .ready(let entries):
            Text(title).font(.headline)
            LazyVGrid(columns: grid, spacing: 16) {
                ForEach(entries) { entry in
                    ThumbnailCell(entry: entry)
                        .onTapGesture { selectedEntry = entry }
                }
            }
        }
    }

    private let grid: [GridItem] = [
        GridItem(.adaptive(minimum: 180), spacing: 16)
    ]

    /// Overall thumbnail-render progress in [0,1], or nil when there's nothing to render.
    private var thumbProgress: Double? {
        guard model.thumbTotal > 0 else { return nil }
        return Double(model.renderedThumbIDs.count) / Double(model.thumbTotal)
    }
}
