# Playback Formats

*Resolution, aspect ratio, and pixel format support for the fractal flame renderer.*

> **Status:** preliminary — for review · Emberweft

## Overview

Emberweft supports a comprehensive range of resolutions, aspect ratios, and pixel formats to accommodate diverse display scenarios — from mobile short-form content to cinema-wide HDR output. The rendering pipeline adapts its sampling and output parameters to each format while maintaining visual quality.

## Resolution Presets

### Standard Resolutions

The following presets are supported with automatic scaling to attached displays:

| Resolution | Dimensions | Aspect Ratio | Target FPS | Typical Use Case |
|------------|------------|--------------|------------|------------------|
| 720p HD | 1280 × 720 | 16:9 | 60 fps | Mobile, battery mode |
| 1080p Full HD | 1920 × 1080 | 16:9 | 60 fps | Default desktop |
| 1440p QHD | 2560 × 1440 | 16:9 | 30 fps | High-end displays |
| 4K UHD | 3840 × 2160 | 16:9 | 30 fps | Cinema, export |
| 5K | 5120 × 2880 | 16:9 | 24 fps | Retina iMac |

**Preliminary defaults:**
- Realtime playback: 1080p at 60 fps
- Export: 4K at 30 fps
- Battery mode: 720p at 30 fps
- Screensaver: Display-native resolution capped at 1080p equivalent

### Device-Native Resolution

For Retina and high-PI displays, the renderer automatically scales to the display's native resolution:

```swift
func nativeResolution(for screen: NSScreen) -> CGSize {
    let backingScale = screen.backingScaleFactor
    let pixelSize = screen.frame.size
    return CGSize(
        width: pixelSize.width * backingScale,
        height: pixelSize.height * backingScale
    )
}
```

**Considerations:**
- Rendering at native 2x or 3x Retina scale quadruples or nonuples the pixel count
- Histogram iteration budget must scale proportionally to maintain visual quality
- Quality setting may auto-downscale on high-PI displays to maintain target fps

### Custom Resolutions

Users may specify arbitrary resolutions up to **(preliminary)** 7680 × 4320 (8K) for export workflows. Realtime playback is recommended only up to 4K due to GPU memory and thermal constraints.

## Aspect Ratios

### Supported Ratios

| Aspect Ratio | Dimensions (1080p base) | Use Case |
|--------------|-------------------------|----------|
| 16:9 | 1920 × 1080 | Standard widescreen, desktop, TV |
| 9:16 | 1080 × 1920 | Mobile portrait, short-form video |
| 1:1 | 1080 × 1080 | Social media square format |
| 21:9 | 2520 × 1080 | Ultrawide, cinematic |
| 4:5 | 1080 × 1350 | Instagram portrait |
| 4:3 | 1440 × 1080 | Classic format |

### Flame Camera Adaptation

The [genome](../rendering/genome-format.md) defines a virtual camera with center position, scale, and rotation parameters. To adapt a sheep (typically authored at 16:9) to other aspect ratios without cropping:

```swift
func adaptCamera(genome: Genome, targetAspect: Float) -> Camera {
    let sourceAspect = 16.0 / 9.0
    let scaleFactor = targetAspect > sourceAspect 
        ? targetAspect / sourceAspect  // Wider: zoom out
        : sourceAspect / targetAspect  // Narrower: zoom in
    
    return Camera(
        center: genome.camera.center,
        scale: genome.camera.scale * scaleFactor,
        rotation: genome.camera.rotation
    )
}
```

**Derivation:**
- The attractor's bounding box is defined in normalized coordinate space [-1, 1]
- Pixel-per-unit is recalculated as `min(width, height) / (2 * scale)`
- This ensures the attractor always fits regardless of aspect

### Letterboxing and Pillarboxing

For export or scenarios where exact dimensions are required:

- **Letterbox** (top/bottom bars): Add black padding to fit wider container
- **Pillarbox** (side bars): Add black padding to fit narrower container
- Padding color is user-configurable (default: black `0x000000`)

## Pixel Formats and Bit Depth

### Realtime Pipeline

**Preview Format (8-bit sRGB):**
- `MTLPixelFormat.bgra8Unorm` — standard UI display format
- Gamma-corrected sRGB output
- Suitable for on-screen playback and typical export

**High-Quality Format (16-bit half-float):**
- `MTLPixelFormat.rgba16Float` — linear color space
- Histogram accumulates in linear space
- Final tone mapping and gamma applied in fragment shader
- Used for export master and when display supports HDR

### HDR Output

For HDR displays and HDR export:

**Rec.2020 + PQ (Perceptual Quantizer):**
- `MTLPixelFormat.rgba16Float` or `MTLPixelFormat.rgba10_xr` (extended range 10-bit)
- Color primaries: Rec.2020 (wider gamut than sRGB)
- Transfer function: SMPTE ST 2084 PQ
- Metadata injection via AVFoundation for HDR video files

**HLG (Hybrid Log-Gamma):**
- Alternative HDR transfer function for broadcast scenarios
- Easier to integrate with SDR content

**HDR Support (preliminary):**
- Detect HDR display via `screen.hasHDR()`
- Fall back to SDR on non-HDR displays
- Export format selectable: SDR (Rec.709) or HDR (Rec.2020 + PQ)

### Color Pipeline

```
[Flame Colors] → [Linear Accumulation] → [Tone Mapping] → [Gamma/Transfer] → [Display]
```

The flame color palette is defined in linear space. The histogram accumulates with linear blending. Tone mapping (Reinhard or ACES filmic) is applied before final transfer function.

## Supersampling

### Histogram Grid Supersampling

The chaos-game histogram is computed at higher resolution than output, then downsampled for anti-aliasing:

```swift
struct SupersampleConfig {
    let outputSize: CGSize
    let ssFactor: Int  // Supersample multiplier
    
    var histogramSize: Int {
        return Int(outputSize.width * ssFactor) * Int(outputSize.height * ssFactor)
    }
}
```

**Supersample Factors (preliminary):**

| Quality Tier | SS Factor | Output Quality | Performance Impact |
|--------------|-----------|----------------|-------------------|
| Low | 1× | jagged edges | baseline |
| Medium | 2× | adequate anti-aliasing | 4× histogram pixels |
| High | 3× | smooth edges | 9× histogram pixels |
| Ultra | 4× | near-perfect | 16× histogram pixels |

The render shader uses linear interpolation during downsample to smooth artifacts.

### Adaptive Supersampling

When GPU cannot maintain target fps, supersample factor is reduced before iteration budget:

```swift
func adaptQuality(measuredFPS: Double, targetFPS: Double) -> QualityConfig {
    if measuredFPS < targetFPS * 0.9 && ssFactor > 1 {
        // Drop SS first for smoother degradation
        return QualityConfig(
            ssFactor: ssFactor - 1,
            iterations: iterations
        )
    } else if measuredFPS > targetFPS * 1.2 && ssFactor < maxSSFactor {
        // Increase SS if headroom available
        return QualityConfig(
            ssFactor: ssFactor + 1,
            iterations: iterations
        )
    }
    return currentConfig
}
```

## Device Adaptation

### Display Capabilities Detection

The renderer queries attached displays for optimal parameters:

```swift
func detectDisplayCapabilities(_ screen: NSScreen) -> DisplayConfig {
    return DisplayConfig(
        nativeSize: nativeResolution(for: screen),
        refreshRate: screen.maximumRefreshRate,  // ProMotion 120Hz
        colorSpace: screen.colorSpace,  // sRGB, Display P3, or Rec.2020
        hdrSupported: screen.hasHDR(),
        metalSupport: screen.device.supportsFamily(.metal4)
    )
}
```

### ProMotion Variable Refresh Rate

On ProMotion displays (120Hz capable):

- Target 120 fps when thermal state nominal
- Automatically scale down to 60 fps on battery
- Use `MTKView.preferredFramesPerSecond` = 120
- CVDisplayLink adapts to actual display refresh

**Power Budgeting (preliminary):**
- 120Hz mode requires ~2× iteration budget vs 60Hz for equivalent quality
- Not available in Low Power mode
- Requires `ProcessInfo.thermalState == .nominal` for sustained operation

### External Display Hot-Plug

When displays are added or removed:

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(displayConfigurationChanged),
    name: NSApplication.didChangeScreenParametersNotification,
    object: nil
)
```

Action: Reinitialize Metal layer at new resolution, revalidate quality settings.

## Format Selection UI

The player UI exposes format controls:

- Resolution picker: 720p / 1080p / 1440p / 4K / Display Native
- Aspect ratio selector: 16:9 / 9:16 / 1:1 / 21:9
- Quality tier: Low / Medium / High / Ultra (controls SS + iterations)
- Color mode: SDR / HDR (auto-detect preferred)
- Refresh rate cap: 30 / 60 / 90 / 120 fps (if supported)

See [`../platform/app-ui.md`](../platform/app-ui.md) for UI implementation details.

## Related Documentation

- [`../rendering/metal-pipeline.md`](../rendering/metal-pipeline.md) — GPU rendering pipeline
- [`../rendering/genome-format.md`](../rendering/genome-format.md) — Genome camera parameters
- [`../export/export-pipeline.md`](../export/export-pipeline.md) — Export format options
- [`../engineering/performance.md`](../engineering/performance.md) — Performance implications

---

**Credits:** The fractal flame algorithm is © Scott Draves. Electric Sheep™ and Infinidream™ are trademarks of Scott Draves and e-dream, inc.
