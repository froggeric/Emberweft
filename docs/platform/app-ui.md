# App UI

*SwiftUI macOS application structure and user experience.*

> **Status:** preliminary — for review · Emberweft

## Overview

Emberweft provides a native macOS application built with SwiftUI that serves as the primary interface for browsing, playing, and exporting fractal flame animations. The app exposes the full capabilities of the rendering engine while maintaining a clean, accessible interface.

## Application Entry and Window Scenes

### App Structure

```swift
@main
struct FlameApp: App {
    @StateObject private var player = FlamePlayer()
    @StateObject private var library = SheepLibrary()
    
    var body: some Scene {
        PlayerScene()
            .environment(player)
            .environment(library)
        
        LibraryScene()
            .environment(library)
        
        SettingsScene()
        
        ExportScene()
            .environment(library)
    }
}
```

### Window Scenes

**Player Scene (main window):**
- Primary window for playback
- Fullscreen capable
- Displays active sheep with controls overlay

**Library Scene:**
- Optional secondary window
- Grid/thumbnail browser
- Inspector for selected sheep details

**Settings Scene:**
- Preferences panel (app-style)
- System settings integration

**Export Scene:**
- Sheet-based, not standalone window
- Triggered from library or player

## Player View

### MTKView Integration

The core player view wraps Metal rendering via `NSViewRepresentable`:

```swift
struct MetalPlayerView: NSViewRepresentable {
    let player: FlamePlayer
    
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.enableSetNeedsDisplay = false  // Manual drive
        view.isPaused = true
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
        // Handle size changes, settings updates
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(player: player)
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        func draw(in view: MTKView) {
            player.renderFrame(view: view)
        }
    }
}
```

**Alternative CAMetalLayer:**

For finer control, a custom `NSView` with direct `CAMetalLayer` attachment may be used instead of `MTKView`.

### Transport Controls

```swift
struct TransportControls: View {
    @ObservedObject var player: FlamePlayer
    @Binding var isFullscreen: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Playback control
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            
            // Navigation
            Button { player.previousSheep() } label: {
                Image(systemName: "backward.fill")
            }
            Button { player.nextSheep() } label: {
                Image(systemName: "forward.fill")
            }
            
            // Scrub
            ScrubberTimeline(player: player)
            
            // Mode toggles
            Picker("Mode", selection: $player.playbackMode) {
                Text("Realtime").tag(PlaybackMode.realtime)
                Text("Cached").tag(PlaybackMode.preRendered)
                Text("Hybrid").tag(PlaybackMode.hybrid)
            }
            
            // Resolution/Quality
            Picker("Quality", selection: $player.quality) {
                Text("Low").tag(Quality.low)
                Text("Medium").tag(Quality.medium)
                Text("High").tag(Quality.high)
                Text("Ultra").tag(Quality.ultra)
            }
            
            // Fullscreen
            Button { isFullscreen.toggle() } label: {
                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "fullscreen")
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}
```

### Scrub Timeline

```swift
struct ScrubberTimeline: View {
    @ObservedObject var player: FlamePlayer
    
    var body: some View {
        VStack {
            // Timeline bar with transition progress
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background: total duration
                    Rectangle().fill(.secondary.opacity(0.3))
                    
                    // Progress: current position
                    Rectangle().fill(.accent)
                        .frame(width: geometry.size.width * player.progress)
                    
                    // Transition markers
                    ForEach(player.upcomingTransitions, id: \.timestamp) { transition in
                        Circle()
                            .fill(.white)
                            .frame(width: 8, height: 8)
                            .position(x: geometry.size.width * transition.progress, y: geometry.size.height / 2)
                    }
                }
                .cornerRadius(4)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            player.seek(to: value.location.x / geometry.size.width)
                        }
                )
            }
            .frame(height: 8)
            
            // Time display
            HStack {
                Text(player.currentTimeFormatted)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(player.remainingTimeFormatted)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
}
```

### Aspect Ratio Toggle

Support for vertical/portrait mode:

```swift
struct AspectRatioToggle: View {
    @Binding var aspect: AspectRatio
    
    var body: some View {
        Picker("Aspect", selection: $aspect) {
            Text("Landscape 16:9").tag(AspectRatio.landscape16x9)
            Text("Portrait 9:16").tag(AspectRatio.portrait9x16)
            Text("Square 1:1").tag(AspectRatio.square)
            Text("Cinema 21:9").tag(AspectRatio.ultrawide21x9)
        }
        .pickerStyle(.segmented)
    }
}
```

## Library Browser

### Grid View

```swift
struct LibraryGridView: View {
    @ObservedObject var library: SheepLibrary
    @State private var selection: Set<Sheep.ID> = []
    
    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 180, maximum: 240))
                ],
                spacing: 16
            ) {
                ForEach(library.sheep) { sheep in
                    SheepThumbnail(sheep: sheep)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selection.contains(sheep.id) ? .accent : .clear, lineWidth: 3)
                        )
                        .onTapGesture {
                            selection = [sheep.id]
                        }
                        .onTapGesture(count: 2) {
                            // Double-click: play this sheep
                            player.play(sheep)
                        }
                }
            }
            .padding()
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Sort by Name") { library.sort(.name) }
                    Button("Sort by Date") { library.sort(.dateCreated) }
                    Button("Sort by Rating") { library.sort(.rating) }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                
                Button {
                    library.importFromFiles()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}
```

### Search and Filter

```swift
struct LibraryFilterView: View {
    @ObservedObject var library: SheepLibrary
    @State private var searchText = ""
    @State private var filterTags: Set<Tag> = []
    @State private var minRating: Int = 0
    
    var body: some View {
        VStack(alignment: .leading) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search library...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.regularMaterial)
            .cornerRadius(8)
            
            // Tag filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(library.availableTags) { tag in
                        TagChip(tag: tag, isSelected: filterTags.contains(tag)) {
                            if filterTags.contains(tag) {
                                filterTags.remove(tag)
                            } else {
                                filterTags.insert(tag)
                            }
                        }
                    }
                }
            }
            
            // Rating filter
            HStack {
                Text("Minimum rating:")
                Picker("Rating", selection: $minRating) {
                    Text("Any").tag(0)
                    Text("★+").tag(1)
                    Text("★★+").tag(2)
                    Text("★★★+").tag(3)
                    Text("★★★★+").tag(4)
                    Text("★★★★★").tag(5)
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.trailing)
        .onChange(of: searchText) { library.filter(search: $0, tags: filterTags, minRating: minRating) }
    }
}
```

### Thumbnail Generation

Thumbnails are generated via background renders:

```swift
func generateThumbnail(for sheep: Sheep, size: CGSize) async -> NSImage {
    let renderer = ThumbnailRenderer(size: size)
    return await renderer.render(sheep: sheep, quality: .preview)
}
```

Thumbnails are cached in the app-group container:
```
~/Library/Group Containers/group.«project».screensaver/Library/Thumbnails/
```

## Inspector Panel

### Sheep Details

```swift
struct SheepInspector: View {
    let sheep: Sheep
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title and rating
            VStack(alignment: .leading) {
                Text(sheep.title).font(.title2)
                RatingView(rating: sheep.rating)
            }
            
            Divider()
            
            // Metadata
            GroupBox("Information") {
                VStack(alignment: .leading, spacing: 4) {
                    InfoRow("Author", sheep.author)
                    InfoRow("Created", sheep.dateCreated.formatted())
                    InfoRow("Genome ID", sheep.genome.id.uuidString.prefix(8))
                    InfoRow("Iterations", "\(sheep.genome.iterations)")
                }
                .font(.caption)
            }
            
            // Tags
            GroupBox("Tags") {
                TagCloud(tags: sheep.tags)
            }
            
            Divider()
            
            // Actions
            VStack(spacing: 8) {
                Button("Play Now") {
                    player.play(sheep)
                }
                .buttonStyle(.borderedProminent)
                
                Button("Edit / Breed") {
                    // Open breed panel
                }
                .buttonStyle(.bordered)
                
                Button("Export Video") {
                    exportSheetPresented = true
                }
                .buttonStyle(.bordered)
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 200, maxWidth: 280)
    }
}
```

## Settings View

### Default Preferences

```swift
struct SettingsView: View {
    @AppStorage("resolution") private var resolution = ResolutionPref.displayNative
    @AppStorage("targetFPS") private var targetFPS = 60
    @AppStorage("transitionLength") private var transitionLength = 8.0
    @AppStorage("energyMode") private var energyMode = EnergyMode.balanced
    @AppStorage("libraryPath") private var libraryPath = ""
    
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gear") }
            
            PlaybackSettings()
                .tabItem { Label("Playback", systemImage: "play") }
            
            ExportSettings()
                .tabItem { Label("Export", systemImage: "share") }
            
            LibrarySettings()
                .tabItem { Label("Library", systemImage: "folder") }
            
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "sliders") }
        }
        .frame(minWidth: 500, minHeight: 350)
    }
}
```

### General Settings

```swift
struct GeneralSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Resolution
            GroupBox("Display Resolution") {
                Picker("Resolution", selection: $resolution) {
                    Text("720p HD").tag(ResolutionPref.p720)
                    Text("1080p Full HD").tag(ResolutionPref.p1080)
                    Text("1440p QHD").tag(ResolutionPref.p1440)
                    Text("4K UHD").tag(ResolutionPref.p4K)
                    Text("Display Native").tag(ResolutionPref.displayNative)
                }
                
                Toggle("Limit to 1080p equivalent on Retina", isOn: $limitRetina)
            }
            
            // Frame rate
            GroupBox("Frame Rate") {
                Picker("Target FPS", selection: $targetFPS) {
                    Text("24 fps (cinematic)").tag(24)
                    Text("30 fps (standard)").tag(30)
                    Text("60 fps (smooth)").tag(60)
                    Text("120 fps (ProMotion only)").tag(120)
                }
                
                Text("Higher frame rates require more GPU power")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Energy mode
            GroupBox("Energy Mode") {
                Picker("Mode", selection: $energyMode) {
                    Text("Performance").tag(EnergyMode.performance)
                    Text("Balanced").tag(EnergyMode.balanced)
                    Text("Efficiency").tag(EnergyMode.efficiency)
                }
                .pickerStyle(.segmented)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Affects iteration budget and FPS caps")
                    Text("Respects Low Power Mode when enabled")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}
```

## Export Sheet

### Export Configuration

```swift
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: SheepLibrary
    
    @State private var config = ExportConfig()
    @State private var isExporting = false
    @State private var exportProgress: ExportProgress?
    
    var body: some View {
        VStack(spacing: 16) {
            // Source selection
            GroupBox("Source") {
                Picker("What to export", selection: $config.source) {
                    Text("Current Sheep").tag(ExportSource.current)
                    Text("Selected Sheep (\(selection.count))").tag(ExportSource.selection)
                    Text("Playlist...").tag(ExportSource.playlist)
                }
            }
            
            // Format
            GroupBox("Format") {
                HStack {
                    Picker("Resolution", selection: $config.resolution) {
                        Text("720p").tag(Resolution.p720)
                        Text("1080p").tag(Resolution.p1080)
                        Text("1440p").tag(Resolution.p1440)
                        Text("4K").tag(Resolution.p4K)
                    }
                    
                    Picker("FPS", selection: $config.fps) {
                        Text("24").tag(24)
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                    
                    Picker("Codec", selection: $config.codec) {
                        Text("HEVC").tag(ExportCodec.hevc)
                        Text("H.264").tag(ExportCodec.h264)
                        Text("ProRes 422").tag(ExportCodec.proRes422)
                    }
                }
            }
            
            // Quality
            GroupBox("Quality") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Quality tier:")
                        Picker("Quality", selection: $config.quality) {
                            Text("Preview").tag(ExportQuality.preview)
                            Text("Standard").tag(ExportQuality.standard)
                            Text("High").tag(ExportQuality.high)
                            Text("Ultra").tag(ExportQuality.ultra)
                        }
                    }
                    
                    HStack {
                        Text("Duration:")
                        TextField("seconds", value: $config.durationSeconds, format: .number)
                            .frame(width: 60)
                        Text("seconds")
                    }
                    
                    Toggle("HDR (Rec.2020 + PQ)", isOn: $config.hdrEnabled)
                }
            }
            
            // Estimated output
            GroupBox("Estimated Output") {
                VStack(alignment: .leading, spacing: 4) {
                    InfoRow("File size", config.estimatedSizeFormatted)
                    InfoRow("Render time", config.estimatedTimeFormatted)
                    InfoRow("Disk location", config.destinationURL.path)
                }
                .font(.caption)
            }
            
            // Progress (when exporting)
            if isExporting, let progress = exportProgress {
                ProgressView(value: progress.percentage)
                Text("\(progress.currentFrame) / \(progress.totalFrames) frames")
                    .font(.caption)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        // Cancel export
                    }
                }
            }
            
            // Actions
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Export") {
                    startExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
            }
        }
        .padding()
        .frame(minWidth: 500)
    }
}
```

## State Management

### Swift 6 Strict Concurrency

```swift
@globalActor
actor FlameActor {
    static let shared = FlameActor()
}

@MainActor
class FlamePlayer: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentSheep: Sheep?
    @Published var playbackMode: PlaybackMode = .hybrid
    
    // State managed via actor for thread-safety
    private let engine = RenderEngine()
    private let library: SheepLibrary
}
```

### Observable View Models

```swift
@MainActor
class LibraryViewModel: ObservableObject {
    @Published var sheep: [Sheep] = []
    @Published var filterCriteria: FilterCriteria = .all
    @Published var sortCriterion: SortCriterion = .dateCreated
    
    func applyFilter() {
        sheep = filteredAndSortedSheep()
    }
}
```

### AppStorage for Preferences

```swift
@AppStorage("defaultResolution") 
private static var defaultResolution: ResolutionPref = .p1080

@AppStorage("showAdvancedSettings")
private static var showAdvanced: Bool = false
```

## Accessibility

### VoiceOver Labels

All controls receive semantic labels:

```swift
Button { player.togglePlayPause() } label: {
    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
}
.accessibilityLabel(player.isPlaying ? "Pause" : "Play")
.accessibilityHint("Toggle playback")
```

### Keyboard Shortcuts

```swift
struct KeyboardShortcuts {
    static let togglePlay = KeyEquivalent(" ")
    static let nextSheep = KeyEquivalent("n")
    static let previousSheep = KeyEquivalent("p")
    static let fullscreen = KeyEquivalent("f")
    static let export = KeyEquivalent("e", modifiers: .command)
}
```

Registered in the app:

```swift
.scene {
    PlayerScene()
        .commands {
            CommandMenu("Playback") {
                Button("Play/Pause") { player.togglePlayPause() }
                    .keyboardShortcut(" ")
                Button("Next Sheep") { player.nextSheep() }
                    .keyboardShortcut("n")
                Button("Fullscreen") { toggleFullscreen() }
                    .keyboardShortcut("f")
            }
        }
}
```

### Reduce Motion Option

```swift
@AppStorage("reduceMotion") 
private var reduceMotion: Bool = false

var transitionAnimation: Animation {
    reduceMotion ? .none : .easeInOut(duration: 0.3)
}
```

## Menu Bar Integration

### Optional Menu Bar Icon

A "Now Dreaming" indicator in the menu bar:

```swift
class MenuBarController {
    private var statusItem: NSStatusItem?
    
    func showIndicator(isPlaying: Bool) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = isPlaying ? NSImage(named: "dreaming-active") : nil
            button.action = #selector(togglePlayer)
        }
    }
}
```

Shows current sheep title and provides quick-play toggle.

### Menu Extras

- Play/Pause
- Next/Previous sheep
- Toggle fullscreen
- Show player window

## Related Documentation

- [`../architecture.md`](../architecture.md) — System architecture and FlamePlayer
- [`../playback/playback-modes.md`](../playback/playback-modes.md) — Playback mode controls
- [`../playback/formats.md`](../playback/formats.md) — Resolution and format options
- [`../library/seed-library.md`](../library/seed-library.md) — Library structure
- [`../export/export-pipeline.md`](../export/export-pipeline.md) — Export pipeline

---

**Credits:** The fractal flame algorithm is © Scott Draves. Electric Sheep™ and Infinidream™ are trademarks of Scott Draves and e-dream, inc.
