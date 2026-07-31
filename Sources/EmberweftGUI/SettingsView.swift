import SwiftUI
import EmberweftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Quality", selection: $model.prefs.qualityPreset) {
                ForEach(AppPreferences.QualityPreset.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Backend", selection: $model.prefs.backend) {
                ForEach(AppPreferences.Backend.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            Picker("Thumbnail backend", selection: $model.prefs.thumbnailBackend) {
                ForEach(AppPreferences.Backend.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .help("CPU renders thumbnails off the main thread (no UI freeze). Metal is faster but blocks the UI per thumbnail.")
            Picker("Target FPS", selection: $model.prefs.targetFPS) {
                Text("24").tag(24); Text("30").tag(30); Text("60").tag(60)
            }
            Stepper("Thumbnail samples: \(model.prefs.thumbnailSPP)",
                    value: $model.prefs.thumbnailSPP, in: 1...64)
            Section {
                if let dir = model.prefs.defaultLibraryDir {
                    Text(dir.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("No directory chosen (curated set only).")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Library directory")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
        .onChange(of: model.prefs) { _, _ in
            try? model.prefs.save()
        }
    }
}
