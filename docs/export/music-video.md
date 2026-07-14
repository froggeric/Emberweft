# Music Video Generation

*Audio-reactive video generation synchronized to music tracks.*

> **Status:** preliminary — for review · Emberweft

## Overview

Emberweft supports audio-reactive music-video generation where visual parameters are driven by audio features extracted from a music track. Two operational modes are supported: **OFFLINE** (analyze entire track, generate deterministic video) and **REALTIME VJ** (live audio input driving live parameter modulation).

## Audio Analysis Pipeline

### Audio Loading

```swift
class AudioAnalyzer {
    private let audioFile: AVAudioFile
    private let asset: AVAsset
    
    init(url: URL) throws {
        self.audioFile = try AVAudioFile(forReading: url)
        self.asset = AVAsset(url: url)
    }
    
    var duration: TimeInterval {
        return asset.duration.seconds
    }
    
    var sampleRate: Double {
        return audioFile.fileFormat.sampleRate
    }
    
    var channelCount: AVAudioChannelCount {
        return audioFile.fileFormat.channelCount
    }
}
```

Supported formats: MP3, AAC, ALAC, WAV, AIFF, FLAC (via AVFoundation).

### Feature Extraction

The analysis pipeline extracts both time-domain and frequency-domain features using Accelerate (vDSP) and AudioToolbox:

#### Onset/Beat Detection

```swift
func detectBeats(audioBuffer: AVAudioPCMBuffer) -> [BeatEvent] {
    // 1. Compute spectral flux
    let spectralFlux = computeSpectralFlux(audioBuffer: audioBuffer)
    
    // 2. Apply adaptive thresholding
    let threshold = movingAverage(spectralFlux, window: 10) * 1.3
    let peaks = spectralFlux.enumerated().filter { 
        $0.element > threshold[$0.offset] 
    }
    
    // 3. Cluster peaks into beat events
    return clusterBeats(peaks, minInterval: 0.3)  // Minimum 300ms between beats
}
```

**Beat Event Structure:**

```swift
struct BeatEvent {
    let timestamp: TimeInterval
    let strength: Float  // 0.0 to 1.0, how "strong" the beat is
    let type: BeatType  // .kick, .snare, .hihat (classified by frequency band)
}
```

#### BPM Estimation

```swift
func estimateBPM(beats: [BeatEvent]) -> Double {
    let intervals = zip(beats, beats.dropFirst()).map { 
        $1.timestamp - $0.timestamp 
    }
    
    // Histogram of intervals to find dominant periodicity
    let histogram = histogram(intervals, binSize: 0.01)
    let dominantInterval = histogram.max(by: { $0.value < $1.value }).key
    
    return 60.0 / dominantInterval
}
```

**Multi-BPM Support:**
- Tracks with tempo changes are segmented by BPM detection window
- Each segment gets its own BPM annotation
- Transitions are smoothed over 4-beat windows

#### RMS and Spectral Features

```swift
func extractFeatures(
    audioBuffer: AVAudioPCMBuffer, 
    hopSize: Int = 512
) -> [AudioFeatures] {
    var features: [AudioFeatures] = []
    let frameCount = audioBuffer.frameLength
    
    for onset in stride(from: 0, to: Int(frameCount), by: hopSize) {
        let frame = audioBuffer.frame(onset: onset, length: hopSize)
        
        // Time-domain
        let rms = computeRMS(frame)
        let zcr = computeZeroCrossingRate(frame)
        
        // Frequency-domain via FFT
        let fft = vDSP.fft(frame)
        let spectrum = vDSP.absolute(fft)
        let bandEnergies = computeBandEnergies(spectrum)
        
        features.append(AudioFeatures(
            timestamp: TimeInterval(onset) / sampleRate,
            rms: rms,
            spectralFlux: 0.0,  // computed across frames
            spectralCentroid: computeCentroid(spectrum),
            bandEnergies: bandEnergies  // [low, mid, high]
        ))
    }
    
    return features
}
```

**Band Energy Definitions (preliminary):**
- **Low**: 20 Hz — 250 Hz (bass, kick)
- **Mid**: 250 Hz — 2 kHz (vocals, snare)
- **High**: 2 kHz — 20 kHz (hi-hat, cymbals)

### Analysis Output

The analysis produces a timeline:

```swift
struct AudioTimeline {
    let duration: TimeInterval
    let bpm: Double
    let beats: [BeatEvent]
    let downbeats: [TimeInterval]  // Bar beginnings (measure starts)
    let features: [AudioFeatures]  // Interpolated to 60 fps
}
```

This timeline is serialized to JSON for reproducibility and for Realtime VJ mode reference.

## Mapping Model

### Parameter Mapping Schema

Audio features map to visual parameters via configurable transfer functions:

```swift
struct MappingRule {
    enum Feature {
        case rms, spectralFlux, spectralCentroid
        case bandEnergy(Band)  // .low, .mid, .high
        case beatStrength, beatInterval
    }
    
    enum Target {
        case scale, zoom, rotation
        case variationWeight(Int)  // Which variation to modulate
        case iterationDensity, colorShift, brightness
        case transitionSpeed, paletteIndex
    }
    
    let source: Feature
    let target: Target
    let curve: TransferFunction  // .linear, .log, .exponential
    let gain: Float  // Sensitivity multiplier
    let range: ClosedRange<Float>  // Output clamping
}
```

### Example Mappings (preliminary defaults)

```swift
let defaultMappings: [MappingRule] = [
    // Bass drives scale/zoom ("thump")
    MappingRule(
        source: .bandEnergy(.low),
        target: .scale,
        curve: .exponential(2.0),
        gain: 0.5,
        range: 0.8...1.5
    ),
    
    // Spectral flux modulates variation weight (chaos on busy sections)
    MappingRule(
        source: .spectralFlux,
        target: .variationWeight(0),
        curve: .linear,
        gain: 0.3,
        range: 0.0...1.0
    ),
    
    // High energy brightens output
    MappingRule(
        source: .bandEnergy(.high),
        target: .brightness,
        curve: .logarithmic,
        gain: 0.8,
        range: 0.5...1.2
    ),
    
    // Beats trigger palette shifts
    MappingRule(
        source: .beatStrength,
        target: .paletteIndex,
        curve: .linear,
        gain: 1.0,
        range: 0.0...1.0
    ),
    
    // RMS affects iteration density (detail on loud sections)
    MappingRule(
        source: .rms,
        target: .iterationDensity,
        curve: .exponential(1.5),
        gain: 0.4,
        range: 0.5...1.5
    ),
    
    // BPM sets sheep-change cadence
    // (Special handling: triggers transition every N beats)
]
```

### BPM-Driven Sheep Changes

Transitions between sheep are scheduled based on musical structure:

```swift
func scheduleTransitions(timeline: AudioTimeline) -> [TransitionEvent] {
    var transitions: [TransitionEvent] = []
    let beatsPerPhrase = 16  // Change sheep every 16 beats (4 bars at 4/4)
    
    for (index, downbeat) in timeline.downbeats.enumerated() {
        if index % beatsPerPhrase == 0 {
            transitions.append(TransitionEvent(
                timestamp: downbeat,
                duration: 4.0,  // 4-second transition synced to tempo
                nextSheep: selectRandomSheep()
            ))
        }
    }
    
    return transitions
}
```

**Alternative Scheduling:**
- Change on chorus detection (feature-based)
- Change on drops (sudden energy increase)
- Manual cue points from user

## Offline Music Video Mode

### Workflow

1. **Load Track**: User selects audio file
2. **Analyze**: Extract full timeline (2-5 seconds per minute of audio)
3. **Review**: Show beat grid, feature waveforms, auto-detected transitions
4. **Adjust**: User edits mapping rules, transition points, sheep selection
5. **Render**: Export video with audio muxed in

### Deterministic Timeline

```swift
class MusicVideoTimeline {
    let audioTimeline: AudioTimeline
    let transitions: [TransitionEvent]
    let mappings: [MappingRule]
    let sheepSequence: [Sheep]
    
    func parameterSet(at timestamp: TimeInterval) -> RenderParameters {
        // Interpolate features at timestamp
        let features = audioTimeline.features.interpolated(at: timestamp)
        
        // Apply mappings
        var params = RenderParameters.default
        for mapping in mappings {
            let value = mapping.apply(to: features)
            params.set(mapping.target, value: value)
        }
        
        // Override if in transition
        if let transition = activeTransition(at: timestamp) {
            params = applyTransition(params, transition: transition)
        }
        
        return params
    }
}
```

### Frame-Accurate Rendering

Each frame is rendered with parameters calculated for its exact timestamp:

```swift
func renderFrame(frameNumber: Int) -> CVPixelBuffer {
    let timestamp = TimeInterval(frameNumber) / fps
    let params = timeline.parameterSet(at: timestamp)
    let sheep = timeline.sheep(at: timestamp)
    
    return renderSheep(sheep, with: params, frameNumber: frameNumber)
}
```

This ensures visual events (e.g., beat-triggered scale bump) align perfectly with audio.

### Audio Muxing

The export pipeline from [`../export/export-pipeline.md`](../export/export-pipeline.md) is extended with audio track:

```swift
let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput)

// Read audio samples from source asset
let audioAsset = AVAsset(url: audioTrackURL)
let audioTrack = audioAsset.tracks(withMediaType: .audio).first!

let reader = try AVAssetReader(asset: audioAsset)
let readerOutput = AVAssetReaderTrackOutput(
    track: audioTrack, 
    outputSettings: nil
)
reader.add(readerOutput)
reader.startReading()

// Copy samples to writer
while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
    audioInput.append(sampleBuffer)
}
```

**Audio Settings (preliminary):**
- Codec: AAC (compatibility) or ALAC (lossless)
- Sample rate: 48 kHz
- Bit depth: 16-bit
- Channels: Stereo

### Default Export Settings

Music videos have specialized defaults:

- Resolution: 1080p at 30 fps or 4K at 24 fps (cinematic)
- Codec: HEVC for efficiency
- Bitrate: 15 Mbps (1080p) or 30 Mbps (4K)
- Audio: AAC 192 kbps or ALAC lossless

## Realtime VJ Mode

### Live Audio Input

```swift
class LiveAudioInput {
    private var engine: AVAudioEngine
    private var tapNode: AVAudioNode
    private let bufferSize: AVAudioFrameCount = 512
    
    func startAnalysis() {
        let format = tapNode.outputFormat(forBus: 0)
        
        tapNode.installTap(
            onBus: 0, 
            bufferSize: bufferSize,
            format: format
        ) { [weak self] buffer, _ in
            self?.analyzeLiveBuffer(buffer)
        }
        
        try? engine.start()
    }
}
```

Input sources:
- Built-in microphone
- Line-in (audio interface)
- System audio (via loopback driver)

### Low-Latency Processing

Realtime mode prioritizes minimal latency over perfect analysis:

**Latency Budget (preliminary):**
- Target: < 50ms end-to-end (audio → visual change)
- Buffer: 256 samples at 48 kHz = 5.3ms
- Analysis: ~2ms per buffer
- Render: Must complete within remaining budget
- Display: Vsync alignment adds up to 16ms at 60Hz

**Strategies:**
- Smaller analysis buffers (256 vs 512 for offline)
- Simplified feature extraction (no full FFT, use bandpass filters)
- Predictive rendering: start frame before buffer completes

### Graceful Degradation

When render time exceeds budget:

```swift
if frameTime > latencyBudget {
    // Reduce analysis quality
    bufferSize = 128  // Fewer samples to process
    
    // Reduce render quality
    quality.iterations *= 0.7
    
    // Skip feature extraction if critically late
    if frameTime > latencyBudget * 2 {
        skipNextAnalysis = true
    }
}
```

User is notified of quality reduction via UI indicator.

### VJ Controls

Realtime mode exposes controls:

- **Gain sensitivity**: Multiplier for all mapping outputs
- **BPM tap**: Manual tempo input when auto-detection fails
- **Hold**: Freeze current parameter set
- **Flash**: Temporary parameter spike (cued visual event)
- **Sheep trigger**: Manually force next sheep

## Synchronization Details

### Variable BPM Handling

Tracks with tempo changes require continuous BPM estimation:

```swift
func continuousBPM(timeline: AudioTimeline) -> [TimeInterval: Double] {
    // Segment by beat consistency
    let segments = segmentByBeatRegularity(timeline.beats)
    
    return segments.map { segment in
        let bpm = estimateBPM(beats: segment.beats)
        return (segment.start, bpm)
    }
}
```

Transition speeds and sheep-change cadence are scaled to local BPM.

### Temporal Drift Correction

For offline rendering with long-form tracks, accumulation of rounding errors can cause drift:

```swift
func driftCorrectedTimestamp(
    frameNumber: Int, 
    fps: Double, 
    audioDuration: TimeInterval
) -> TimeInterval {
    let nominalTime = TimeInterval(frameNumber) / fps
    
    // Rescale to ensure final frame aligns exactly with audio end
    let scale = audioDuration / (totalFrames / fps)
    
    return nominalTime * scale
}
```

### Beat-Locked Rendering

For strongest musical effect, parameters update on beat boundaries, not continuously:

```swift
func beatLockedValue(
    at timestamp: TimeInterval, 
    parameter: Parameter,
    timeline: AudioTimeline
) -> Float {
    let precedingBeat = timeline.beats.last { $0.timestamp <= timestamp }!
    
    // Hold value from beat onset until next beat
    return parameter.value(at: precedingBeat.timestamp)
}
```

This creates "stepped" effects that sync visually to rhythm.

## Related Documentation

- [`../export/export-pipeline.md`](../export/export-pipeline.md) — Export rendering pipeline
- [`../rendering/transitions.md`](../rendering/transitions.md) — Transition interpolation
- [`../playback/playback-modes.md`](../playback/playback-modes.md) — Realtime playback considerations

---

**Credits:** The fractal flame algorithm is © Scott Draves. Electric Sheep™ and Infinidream™ are trademarks of Scott Draves and e-dream, inc.
