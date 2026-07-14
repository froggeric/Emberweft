# Export Pipeline

*Offline rendering and encoding for video file output.*

> **Status:** preliminary — for review · Emberweft

## Overview

The export pipeline renders fractal flame animations deterministically to video files. Unlike realtime playback, export mode uses fixed iteration budgets and reproducible RNG seeding to ensure frame-accurate, consistent output across multiple renders. The pipeline supports multiple codecs, resolutions, and quality settings for workflows from preview to mastering.

## Deterministic Frame Rendering

### Fixed RNG Seeding

Each sheep uses a deterministic RNG sequence seeded from its genome:

```swift
struct RenderContext {
    let sheep: Sheep
    let frameNumber: Int
    let fixedSeed: UInt64
    
    init(sheep: Sheep, frameNumber: Int) {
        self.sheep = sheep
        self.frameNumber = frameNumber
        // Seed derived from sheep ID + frame offset
        self.fixedSeed = sheep.hashValue ^ UInt64(frameNumber)
    }
    
    func renderFrame(commandBuffer: MTLCommandBuffer) -> MTLTexture {
        var rng = xoroshiro256plus(seed: fixedSeed)
        // Execute chaos-game with fixed iteration count
        let iterations = exportSettings.iterationsPerFrame
        return computeHistogram(iterations: iterations, rng: &rng)
    }
}
```

**Determinism Guarantees:**
- Same genome + same settings → byte-identical output
- Frame seek and re-render always produce identical pixels
- Export reproducibility across machines with same Metal device

### Sample Count Independence

Realtime playback adjusts iteration count for target fps. Export uses fixed iteration counts:

```swift
enum ExportQuality {
    case preview      // 500M iterations/frame
    case standard     // 2B iterations/frame  
    case high         // 5B iterations/frame
    case ultra        // 10B iterations/frame
}
```

This ensures visual quality is independent of rendering hardware capabilities.

## Render Queue Model

### Queue Architecture

The export system uses a job-queue model for sequential or batch rendering:

```swift
class ExportQueue {
    private var queue: [ExportJob] = []
    private var currentJob: ExportJob?
    private var progress: ExportProgress
    
    func enqueue(_ job: ExportJob) {
        queue.append(job)
        if currentJob == nil {
            processNextJob()
        }
    }
    
    private func processNextJob() {
        guard let job = queue.first else { return }
        currentJob = job
        renderJob(job) { [weak self] result in
            self?.queue.removeFirst()
            self?.processNextJob()
        }
    }
}
```

### Job Types

**Single Sheep:**
- Render a single sheep for specified duration
- Optionally loop with seamless (if sheep authored for loop)

**Transition Chain:**
- Sequence of sheep with specified transitions between each
- Total duration = sum of individual sheep durations + transition durations

**Playlist:**
- Ordered list of sheep, each with independent duration
- Useful for curated exports

**Job Structure:**

```swift
struct ExportJob {
    var id: UUID
    var source: ExportSource  // .sheep, .transition, .playlist
    var settings: ExportSettings
    var destination: URL
    var progressHandler: (ExportProgress) -> Void
    var completion: (Result<ExportOutput, ExportError>) -> Void
}
```

## Rendering Pipeline

### Offscreen Rendering

Export renders to offscreen Metal textures, not to a view:

```swift
class ExportRenderer {
    private let texturePool: MTLTexturePool
    private let pixelBufferPool: CVPixelBufferPool
    
    func renderFrame(
        frameNumber: Int, 
        into texture: MTLTexture
    ) -> CVPixelBuffer {
        commandBuffer = commandQueue.makeCommandBuffer()
        
        // Compute pass: chaos-game histogram
        computeEncoder = commandBuffer.makeComputeCommandEncoder()
        executeChaosGame(texture: texture, frame: frameNumber)
        computeEncoder.endEncoding()
        
        // Render pass: tone map and copy to pixel buffer
        renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        
        // Acquire pixel buffer from pool
        let pixelBuffer = pixelBufferPool.createPixelBuffer()
        
        // Blit to pixel buffer
        blitEncoder = commandBuffer.makeBlitCommandEncoder()
        blitEncoder.copy(texture, to: pixelBuffer)
        blitEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        return pixelBuffer
    }
}
```

### Texture and Buffer Pooling

To avoid allocation churn:

- **Texture pool**: Pre-allocated MTLTextures in rotation (size = 3 for pipeline)
- **Pixel buffer pool**: CVPixelBufferPool for AVFoundation integration
- **Histogram buffers**: Reused across frames, cleared between renders

### Memory Management

For long exports **(preliminary)**:
- Frame cache limited to most recent 100 frames
- Completed segments written to disk immediately
- Peak memory usage: ~500MB for 1080p export, ~2GB for 4K

## AVFoundation Encoding

### AVAssetWriter Configuration

```swift
let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)

let videoSettings: [String: Any] = [
    AVVideoCodecKey: codec.avCodec,  // HEVC, H.264, ProRes, etc.
    AVVideoWidthKey: settings.resolution.width,
    AVVideoHeightKey: settings.resolution.height,
    AVVideoCompressionPropertiesKey: compressionProperties
]

let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: writerInput,
    sourcePixelBufferAttributes: nil
)
```

### Codec Matrix

| Codec | File Extension | Bit Depth | Use Case | Compression Efficiency |
|-------|----------------|-----------|----------|------------------------|
| HEVC (H.265) | .mov, .mp4 | 8/10-bit | Standard export | High (best file size) |
| H.264 | .mov, .mp4 | 8-bit | Maximum compatibility | Medium |
| ProRes 422 | .mov | 10-bit | Editing intermediate | Low (large files) |
| ProRes 4444 | .mov | 12-bit + Alpha | Mastering with alpha | Very Low |
| AV1 | .mov, .mp4 | 8/10-bit | Modern efficiency | Very High (slower encode) |

### Bitrate Guidelines (preliminary)

**HEVC (H.265):**
- 720p @ 30fps: 5 Mbps
- 1080p @ 30fps: 10 Mbps
- 1080p @ 60fps: 15 Mbps
- 4K @ 30fps: 30 Mbps
- 4K @ 60fps: 50 Mbps

**H.264 (multiply by ~1.5× for equivalent quality):**
- 1080p @ 30fps: 15 Mbps
- 4K @ 30fps: 45 Mbps

**ProRes (constant bitrate, not VBR):**
- ProRes 422: ~147 Mbps for 1080p, ~550 Mbps for 4K
- ProRes 4444: ~220 Mbps for 1080p, ~880 Mbps for 4K

### HDR Metadata Injection

For HDR exports (Rec.2020 + PQ):

```swift
let compressionProperties: [String: Any] = [
    AVVideoAverageBitRateKey: bitrate,
    
    // HDR metadata
    kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
    kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
    kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_2020,
    
    // Mastering display metadata
    AVVideoMasteringDisplayColorVolumeKey: [
        AVVideoMasteringDisplayColorVolumeRedPoint: [0.708, 0.292],
        AVVideoMasteringDisplayColorVolumeGreenPoint: [0.170, 0.797],
        AVVideoMasteringDisplayColorVolumeBluePoint: [0.131, 0.046],
        AVVideoMasteringDisplayColorVolumeWhitePoint: [0.3127, 0.3290],
        AVVideoMasteringDisplayColorVolumeMinLuminance: 0.0,
        AVVideoMasteringDisplayColorVolumeMaxLuminance: 1000
    ] as [String: Any]
]
```

## Long-Form Export

### Segmented Rendering

For exports longer than **(preliminary)** 10 minutes, rendering is segmented to avoid memory growth:

```swift
func renderLongForm(job: ExportJob) {
    let segmentDuration: TimeInterval = 300  // 5 minutes per segment
    var segmentFiles: [URL] = []
    
    for segmentStart in stride(from: 0, to: job.duration, by: segmentDuration) {
        let segmentURL = temporaryFile()
        renderSegment(
            from: segmentStart, 
            duration: min(segmentDuration, job.duration - segmentStart),
            to: segmentURL
        )
        segmentFiles.append(segmentURL)
    }
    
    concatenateSegments(segmentFiles, to: job.destination)
}
```

### Concatenation

Segments are concatenated using `AVAsset`:

```swift
func concatenateSegments(_ urls: [URL], to destination: URL) {
    let composition = AVMutableComposition()
    var currentTime = CMTime.zero
    
    for url in urls {
        let asset = AVAsset(url: url)
        let assetTimeRange = CMTimeRange(
            start: .zero,
            duration: asset.duration
        )
        
        guard let track = asset.tracks(withMediaType: .video).first else { continue }
        let compositionTrack = composition.addMutableTrack(
            withMediaType: .video, 
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        try? compositionTrack.insertTimeRange(
            assetTimeRange, 
            of: track, 
            at: currentTime
        )
        
        currentTime = CMTimeAdd(currentTime, asset.duration)
    }
    
    // Write composition to destination
    let exportSession = AVAssetExportSession(
        asset: composition, 
        presetName: AVAssetExportSessionPresetPassthrough
    )
    exportSession?.outputURL = destination
    exportSession?.outputFileType = .mov
    exportSession?.exportAsynchronously()
}
```

### Progress Reporting

Progress is reported via callback:

```swift
struct ExportProgress {
    let jobID: UUID
    let currentFrame: Int
    let totalFrames: Int
    let elapsed: TimeInterval
    let estimatedRemaining: TimeInterval
    let outputFileSize: Int64?
    
    var percentage: Double {
        return Double(currentFrame) / Double(totalFrames)
    }
}
```

UI shows:
- Frame count: `currentFrame / totalFrames`
- Percentage bar
- Time elapsed / time remaining
- Current output file size (if determinable)
- Render speed: `framesPerSecond`

### Cancellation

Exports can be cancelled via:

```swift
class ExportJob {
    private var isCancelled = false
    
    func cancel() {
        isCancelled = true
        assetWriter.cancelWriting()
    }
    
    private func renderLoop() {
        while !isCancelled && currentFrame < totalFrames {
            renderAndWriteFrame(currentFrame)
            currentFrame += 1
        }
        
        if isCancelled {
            cleanupPartialFile()
            completionHandler(.cancelled)
        }
    }
}
```

Partial files are deleted on cancellation.

## Background Rendering

### Off-Main-Thread Queue

Export runs on a background serial queue:

```swift
let exportQueue = DispatchQueue(
    label: "com.«project».export", 
    qos: .userInitiated
)
```

### macOS Background Tasks

Optionally submit export as a `BGProcessingTask` for long exports that continue when app is backgrounded:

```swift
func submitBackgroundTask(_ job: ExportJob) throws {
    let task = try BGProcessingTask(
        identifier: "com.«project».export.\(job.id)",
        using: nil
    )
    
    task.expirationHandler = {
        // Save state for resumption
        job.saveCheckpoint()
        task.setTaskCompleted(success: false)
    }
    
    renderJob(job) { result in
        task.setTaskCompleted(success: (result == .success))
    }
}
```

**Limitations:**
- Background tasks are limited by system scheduler
- May be paused/delayed under system pressure
- Not suitable for real-time requirements

## Export Settings UI

### Settings Surface

The export sheet presents:

**Basic:**
- Resolution: 720p / 1080p / 1440p / 4K / Custom
- Frame rate: 24 / 30 / 60 fps
- Duration: seconds or frames
- Codec: HEVC / H.264 / ProRes / AV1

**Advanced:**
- Quality tier: Preview / Standard / High / Ultra
- Iteration multiplier: slider from 0.5× to 5.0× base
- Supersample: 1× to 4×
- Color mode: SDR / HDR (Rec.2020 + PQ)
- Bitrate: Auto (based on codec/res) or Manual slider

**Metadata:**
- Title: Sheep name or custom
- Tags: keywords
- License/attribution: embed in file metadata

### Presets

Predefined presets for common workflows:

- **YouTube** — 1080p60, H.264, 15 Mbps
- **Vimeo** — 4K30, HEVC, 30 Mbps
- **Master** — 4K ProRes 4444, uncompressed
- **Preview** — 720p30, H.264, 5 Mbps
- **Mobile** — 1080p30, HEVC, 8 Mbps

## Audio Muxing Hook

By default, exported files have no audio track. An empty audio track structure is prepared for [`../export/music-video.md`](../export/music-video.md) integration:

```swift
let audioSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVNumberOfChannelsKey: 2,  // Stereo placeholder
    AVSampleRateKey: 48000
]

let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)

// No samples appended — produces silent track
writer.add(audioInput)
```

## Metadata Embedding

### File Metadata

Genome and attribution information is embedded in the video file metadata:

```swift
let metadata: [AVMetadataItem] = [
    createMetadataItem(
        key: AVMetadataCommonKeyTitle,
        value: sheep.title
    ),
    createMetadataItem(
        key: AVMetadataCommonKeyDescription,
        value: sheep.description
    ),
    createMetadataItem(
        key: "com.«project».genome",
        value: sheep.genomeData
    ),
    createMetadataItem(
        key: "com.«project».license",
        value: sheep.license
    ),
    createMetadataItem(
        key: AVMetadataCommonKeyCreator,
        value: "Emberweft"
    )
]

writer.metadata = metadata
```

### EXIF-style Block

For formats that support it (ProRes MOV), add an EXIF metadata block with:

- Render timestamp
- Renderer version
- Quality settings used
- Total iteration count

## Related Documentation

- [`../rendering/metal-pipeline.md`](../rendering/metal-pipeline.md) — GPU rendering pipeline
- [`../playback/formats.md`](../playback/formats.md) — Resolution and format details
- [`../export/music-video.md`](../export/music-video.md) — Audio-reactive export
- [`../engineering/performance.md`](../engineering/performance.md) — Performance considerations

---

**Credits:** The fractal flame algorithm is © Scott Draves. Electric Sheep™ and Infinidream™ are trademarks of Scott Draves and e-dream, inc.
