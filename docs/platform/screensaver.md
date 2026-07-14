# Screensaver Integration

*macOS ScreenSaver.framework integration for the fractal flame renderer.*

> **Status:** preliminary — for review · Emberweft

## Overview

Emberweft distributes as a native macOS screensaver bundle (`.saver`) using the ScreenSaver.framework. The screensaver hosts the Metal rendering pipeline in an energy- and memory-conscious mode, providing an ambient visual experience when the system is idle.

## Distribution Format

### .saver Bundle

The screensaver is distributed as a `.saver` bundle, which is a macOS bundle with specific structure:

```
Emberweft.saver/
├── Contents/
│   ├── Info.plist          (Bundle metadata, NSPrincipalClass)
│   ├── MacOS/
│   │   └── screensaver      (Executable binary)
│   ├── Resources/
│   │   └── (Icon, preview images)
│   └── CodeSignature
```

**Installation:**
User double-clicks the `.saver` bundle. macOS presents an installation dialog. When approved, the bundle is copied to `~/Library/Screen Savers/` or `/Library/Screen Savers/` (system-wide).

**Modern macOS Behavior:**
On macOS 26, screensavers are configured via:
- System Settings → Screen Saver
- Legacy preference pane APIs are deprecated but still functional
- The `.saver` plugin model remains supported

### Wallpaper / Screen-Erase Mode (preliminary)

A "wallpaper" mode that runs continuously on the desktop (behind icons) is under consideration:

- **Benefits**: Persistent display, more interactive
- **Challenges**: Higher energy impact, desktop clutter
- **Status**: Preliminary exploration only; no commitment

This mode would require separate entitlements and may not be feasible under current App Store guidelines.

## Architecture

### ScreenSaverView Subclass

The screensaver's view class inherits from `ScreenSaverView`:

```swift
import ScreenSaver
import Metal
import CoreVideo

@objc(FlameScreenSaverView)
class FlameScreenSaverView: ScreenSaverView {
    private var metalLayer: CAMetalLayer!
    private var player: FlamePlayer!
    private var displayLink: CVDisplayLink!
    
    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setupMetal()
        setupPlayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    override func startAnimation() {
        super.startAnimation()
        // Resume GPU work, start display link
        displayLink = CVDisplayLink(...)
        player.resume()
    }
    
    override func stopAnimation() {
        player.pause()
        CVDisplayLinkStop(displayLink)
        super.stopAnimation()
    }
    
    override func animateOneFrame() {
        // Render one frame and present
        player.renderFrame()
        metalLayer.present()
    }
}
```

### Metal Layer Integration

The screensaver hosts a `CAMetalLayer` for GPU-accelerated rendering:

```swift
func setupMetal() {
    metalLayer = CAMetalLayer()
    metalLayer.device = MTLCreateSystemDefaultDevice()
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = true
    metalLayer.displaySyncEnabled = true
    
    // Attach to view's layer
    wantsLayer = true
    layer = metalLayer
}
```

**Sizing:**
The Metal layer is sized to match the screen bounds, accounting for the `isPreview` flag (small preview in System Settings).

### FlamePlayer in Screensaver Mode

The core rendering logic from [`../architecture.md`](../architecture.md) is reused with screensaver-specific constraints:

```swift
extension FlamePlayer {
    static func screensaverInstance() -> FlamePlayer {
        var config = FlamePlayer.Config()
        
        // Energy-conscious settings
        config.targetFPS = 30  // Capped from 60
        config.iterationBudget = 1_500_000_000  // Reduced from 2B+
        config.resolution = .displayNative  // But may downscale
        config.quality = .medium  // Not high/ultra
        config.mode = .hybrid  // Prefer cached
        
        return FlamePlayer(config: config)
    }
}
```

**Screensaver-Specific Constraints:**
- Target fps capped at **(preliminary)** 30 fps (not 60)
- Iteration budget reduced by ~25-40% vs app mode
- Quality defaults to "Medium" (not High/Ultra)
- Hybrid mode prefers cached content
- Triple-buffering disabled to save memory (double-buffer only)

## Playback Configuration

### Default Behavior

**Screensaver Mode = Curated Library Playback:**

By default, the screensaver plays from the curated seed library described in [`../library/seed-library.md`](../library/seed-library.md):

- Sheep are sequenced with transitions
- Default transition length: **(preliminary)** 12 seconds (slower than app)
- Random walk through library (no user-driven queue)
- Loop indefinitely (when library exhausted, restart)

### Realtime Generation Toggle

A user setting enables realtime generation:

**OFF by default (energy savings):**
- Only pre-rendered cached sheep are played
- Minimal GPU involvement (decode only)
- Near-zero CPU overhead

**ON by user choice:**
- Realtime generation active
- Higher energy cost
- Infinite variety (not limited to cached content)

**Configuration UI (Sheet):**

```
┌───────────────────────────────────────────────┐
│ Emberweft Screensaver Settings                │
├───────────────────────────────────────────────┤
│ Library: [Curated ▼]                          │
│                                               │
│ □ Realtime generation (uses more energy)      │
│                                               │
│ Resolution: [Display Native ▼]               │
│   ☐ Limit to 1080p equivalent                 │
│                                               │
│ Transition length: [12 seconds ▼]            │
│                                               │
│ □ Mute (no audio) [Always checked]           │
│                                               │
│ □ Pause on battery below: [15% ▼]            │
├───────────────────────────────────────────────┤
│              [  Save  ]  [ Cancel  ]          │
└───────────────────────────────────────────────┘
```

**Note:** Audio is always muted in screensaver mode. Music video mode is disabled.

## Power and Thermal Management

### Thermal State Monitoring

The screensaver aggressively manages thermal state:

```swift
func checkThermalState() {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:
        // Allow normal operation
        if pausedForThermal { resume() }
    case .fair:
        // Reduce iteration budget
        player.iterationBudget *= 0.8
    case .serious:
        // Cap fps at 24
        player.targetFPS = 24
    case .critical:
        // Force cached-only or pause
        if cachedAvailable {
            player.mode = .preRendered
        } else {
            pause()
            pausedForThermal = true
        }
    }
}
```

Thermal state is polled every **(preliminary)** 5 seconds.

### Battery Awareness

**Pause on Battery Threshold:**

```swift
func checkBatteryState() {
    let batteryLevel = IOPSBatteryState.currentLevel
    
    if batteryLevel < settings.batteryPauseThreshold {
        // Pause screensaver to conserve battery
        stopAnimation()
        showLowBatteryWarning()
    }
}
```

**Battery-based quality scaling:**
- On battery power: iteration budget × 0.6
- On AC power: normal budget

### Display Sleep Coordination

The screensaver cooperates with display sleep:

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    self,
    selector: #selector(screensWillSleep),
    name: NSWorkspace.screensDidSleepNotification,
    object: nil
)

@objc func screensWillSleep() {
    // Stop GPU work immediately
    stopAnimation()
    releaseMetalResources()
}

@objc func screensDidWake() {
    // Reinitialize Metal pipeline
    reinitializeMetal()
    startAnimation()
}
```

**When display sleeps:**
- All GPU work ceases
- Metal command buffers released
- Texture pools flushed

**On wake:**
- Metal pipeline reinitialized
- First frame rendered and displayed

### Minimal CPU When Display Off

Between frames, the screensaver yields CPU:

```swift
override func animateOneFrame() {
    player.renderFrame()
    metalLayer.present()
    
    // Yield until next frame needed
    let frameInterval = 1.0 / 30.0
    Thread.sleep(forTimeInterval: frameInterval * 0.8)
}
```

Idle CPU usage target: **(preliminary)** < 2% when between frames.

## Configuration UI

### Settings Sheet

The screensaver provides a configuration sheet (accessed via Screen Saver preferences):

**Implementation:**

```swift
override var hasConfigurationSheet: Bool {
    return true
}

override var configureSheet: NSWindow? {
    let controller = ScreensaverConfigSheet()
    controller.settings = currentSettings
    return controller.window
}
```

**Persisted Settings:**

Stored in `UserDefaults.standard` with screensaver-specific prefix:

```swift
let screensaverDefaults = UserDefaults.standard
screensaverDefaults.set(true, forKey: "com.«project».screensaver.realtimeEnabled")
screensaverDefaults.set(15, forKey: "com.«project».screensaver.batteryThreshold")
```

### Preview Support

System Settings shows a small preview. The screensaver detects this via `isPreview`:

```swift
override init?(frame: NSRect, isPreview: Bool) {
    super.init(frame: frame, isPreview: isPreview)
    
    if isPreview {
        // Accelerated preview: 2-second loop, lower quality
        config.previewMode = true
        config.targetFPS = 15
    }
}
```

Preview mode renders faster cycles for immediate visual feedback.

## Security and Sandboxing

### Sandboxed Host Process

Screensavers run in a constrained host process (`ScreenSaverEngine`):

**Allowed locations:**
- Read-only: `.saver` bundle resources, app-group container
- Write: None (no write access except possibly temp)

**App-Group Container:**

To share the sheep library with the main app, both use an app group:

**Entitlement (screensaver):**

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.«project».screensaver</string>
</array>
```

**Library Path:**

```
~/Library/Group Containers/group.«project».screensaver/Library/Sheep/
```

The screensaver reads cached `.mov`/`.mp4` files from this location.

### No Network Access

Screensavers must be fully self-contained:

- No network requests (no fetch from internet)
- All content must be pre-installed or bundled
- Main app populates the app-group container

### Code Signature

The `.saver` bundle is code-signed:

```bash
codesign --force --deep --sign "Developer ID Application: ..."
        Emberweft.saver
```

**Notarization:**
For distribution outside App Store, the bundle is notarized with Apple:

```bash
xcrun notarytool submit Emberweft.saver.zip ...
```

## Installation Notes

### User Installation

1. User downloads `Emberweft.saver`
2. Double-clicks bundle
3. System prompts: "Install this screensaver?"
4. On approval, copied to `~/Library/Screen Savers/`
5. Appears in System Settings → Screen Saver dropdown

### System Installation

For all users:

```bash
sudo cp Emberweft.saver /Library/Screen\ Savers/
```

Requires admin privileges.

### First Launch

On first launch, screensaver creates:

- App-group container directory structure
- Default library symlink or copy
- Initial settings with defaults

If library is empty, shows placeholder message or minimal demo content.

## Related Documentation

- [`../architecture.md`](../architecture.md) — System architecture and FlamePlayer
- [`../playback/playback-modes.md`](../playback/playback-modes.md) — Playback mode details
- [`../library/seed-library.md`](../library/seed-library.md) — Curated library structure
- [`../engineering/performance.md`](../engineering/performance.md) — Performance targets

---

**Credits:** The fractal flame algorithm is © Scott Draves. Electric Sheep™ and Infinidream™ are trademarks of Scott Draves and e-dream, inc.
