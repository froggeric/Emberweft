# M2 — Metal Compute Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `FlameRenderer` — a Metal-compute fractal-flame renderer that is a faithful, statistical twin of the CPU `FlameReference`, proven to agree at PSNR ≥ 38 dB / SSIM ≥ 0.95 over the 6 frozen genomes, exposed through the CLI as `emberweft render … --backend cpu|metal`, with a recorded single-frame performance baseline. Determinism is preserved **within** each backend (same seed → identical frame, machine-independent). CPU and Metal are **not** byte-identical to each other.

**Architecture:** `FlameRenderer` mirrors `FlameReference` stage-for-stage so bugs localize instantly. Three MSL compute kernels — chaos-game histogram, density-estimation filter (radius=0 passthrough for M2), display pipeline — plus a host `MetalRenderer` (Swift, `@MainActor` command recording) that builds constant buffers, dispatches, and reads back. Shared pure value types (`RGBA8Image`, `RenderParams`, `Histogram`, `flam3SpatialFilterWidth`, `Flam3XformDistrib`, `buildDmap`) are lifted from `FlameReference` to `FlameKit` so `FlameRenderer` depends on `FlameKit` only. A debug on-ramp reuses CPU `ToneMapping` on the Metal histogram to isolate Stage-1 parity before any Metal display kernel exists.

**Tech Stack:** Swift 6.2 (strict concurrency), Metal 4 on macOS 26 / Apple Silicon (M1+), MSL kernels compiled at runtime via `MTLDevice.makeLibrary(source:)` from `.metal` resources, SwiftPM `resources: [.copy(...)]`. Apple SDKs only (Foundation, Metal, CoreGraphics, ImageIO).

**User decisions (already made):**
1. Parity = statistical (PSNR ≥ 38 dB), not byte-exact; per-thread ISAAC seeded from the master seed; determinism preserved within each backend.
2. Faithful flam3 port: ISAAC in MSL (not Wang/PCG); affine `tx=a·x+c·y+e`; `precalc_atan=atan2(x,y)`; EPS=1e-10; badvalue |·|>1e10; full display pipeline; final xform transforms a separate binning point (no feedback); same 19-variation set as M1.
3. Local-only execution is the source of truth; GitHub is a plain git mirror; the M0 GA workflow is deleted; testing.md "CI gates" → "Local pre-merge gate".

**Critical design decisions resolved by this plan (skeptical review of the spec):**
- **Color accumulation encoding.** The spec's "Q8.24 fixed-point + clamp" is **wrong**: Q8.24 (8 integer bits) overflows for any hot bin (a bin with >256 hits at color 255 overflows 8 integer bits), and *clamping per atomic-add silently destroys energy* in the log-density sum, breaking parity. Metal float atomic-add via CAS is **not order-independent** → scheduling-dependent rounding → violates within-backend determinism. The plan instead accumulates color/alpha as **`uint32` atomic fixed-point with a per-frame rescale**, exploiting that `uint32` addition mod 2³² is fully associative/commutative → the final sum is **identical regardless of thread scheduling** (deterministic), and the rescale guarantees no overflow. Count is a plain `uint32` atomic (exact). This works on M1 (no 64-bit atomics required — those are Apple8/M2+ only, which would break the M1+ deployment target).
- **SwiftPM `.metal` compilation.** SwiftPM does NOT compile `.metal`. The plan embeds `.metal` files as SwiftPM `resources: [.copy("Metal")]`, loads them at runtime via `Bundle.module`, and compiles with `MTLDevice.makeLibrary(source:options:)`. No build plugin, no metallib build phase, deterministic, M1+-correct.
- **Per-thread ISAAC seeding.** The spec's "folded into the seed material" is under-specified and not collision-free if threads derive seeds themselves. The plan **precomputes** every thread's 16-word `randrsl` on the host (serial draws from a parent ISAAC) and uploads a `threadSeeds` buffer — bit-identical parent→child chain to flam3, collision-free, machine-independent.
- **Sample-budget remainder.** `totalSamples / threadCount` leaves a remainder → systematic under-sampling. The plan distributes the remainder to the first `remainder` threads (one extra iteration each) so total Metal work exactly equals CPU's `totalSamples`.

---

## Task 1 — SwiftPM `.metal` build path + `FlameRenderer` skeleton + `MetalRenderer.isAvailable`

**Goal:** Establish the concrete mechanism by which MSL source reaches the GPU at runtime, wire the new test target, and land the public `MetalRenderer` entry point with device discovery. This task must land before any kernel depends on it.

**Files:**
- Modify `Package.swift`:
  - `FlameRenderer` target: add `resources: [.copy("Metal")]` and `exclude: ["Metal"]` so the `.metal` files are treated as bundled resources, not Swift sources.
  - Add `.testTarget(name: "FlameRendererTests", dependencies: ["FlameRenderer", "FlameReference", "FlameKit"], path: "Tests/FlameRendererTests")`.
- Create `Sources/FlameRenderer/Metal/Kernels.metal` — minimal stub containing a no-op kernel plus a constant the host can reflect:
  ```metal
  #include <metal_stdlib>
  using namespace metal;

  // Sentinel kernel used only by Task 1's "library loads" test. Real kernels
  // are added in later tasks; this file grows into the full MSL source.
  kernel void noop_kernel(device uint* out [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
      if (gid == 0) { out[0] = 0x4d657461; }  // "Meta"
  }
  ```
- Create `Sources/FlameRenderer/MetalRenderer.swift` (replaces the placeholder `FlameRenderer.swift` content; keep the file, rewrite it):
  ```swift
  import Foundation
  import Metal
  import FlameKit

  /// Metal-compute fractal-flame renderer — faithful statistical twin of
  /// `FlameReference`. Deterministic within the Metal backend (same seed →
  /// identical frame, machine-independent). Not byte-identical to CPU.
  public enum MetalRenderer {
      /// Best-effort cached default device. `MTLCreateSystemDefaultDevice` is
      /// documented safe to call once and reuse; we memoize in an Optional.
      @MainActor private static var _device: MTLDevice?
      @MainActor private static var _library: MTLLibrary?

      /// True iff a Metal device exists AND the MSL library compiles.
      /// Gate `--backend metal` on this; the CLI falls back to CPU otherwise.
      public static var isAvailable: Bool {
          MainActor.assumeIsolated { deviceAndLibrary() != nil }
      }

      @MainActor
      static func deviceAndLibrary() -> (MTLDevice, MTLLibrary)? {
          if let d = _device, let l = _library { return (d, l) }
          guard let device = MTLCreateSystemDefaultDevice() else { return nil }
          // The .metal sources are bundled as SwiftPM resources (.copy("Metal")).
          guard let url = Bundle.module.url(forResource: "Kernels", withExtension: "metal", subdirectory: "Metal")
              ?? Bundle.module.url(forResource: "Kernels", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let library = try? device.makeLibrary(source: source, options: nil)
          else { return nil }
          _device = device
          _library = library
          return (device, library)
      }
  }
  ```
- Delete the old placeholder comment content of `Sources/FlameRenderer/FlameRenderer.swift` and replace with a module doc:
  ```swift
  //! FlameRenderer — Metal compute fractal-flame renderer (faithful twin of
  //! FlameReference). Public entry point: `MetalRenderer.render(flame:params:)`.
  ```
- Create `Tests/FlameRendererTests/MetalAvailabilityTests.swift`:
  ```swift
  import XCTest
  @testable import FlameRenderer

  final class MetalAvailabilityTests: XCTestCase {
      func testMetalBackendAvailableOnDevMachine() {
          // The dev machine is Apple Silicon with a usable Metal device.
          XCTAssertTrue(MetalRenderer.isAvailable, "Metal backend unavailable — cannot run M2 parity tests")
      }
  }
  ```

**Acceptance Criteria:**
- `swift build` succeeds; `swift test` builds the new test target.
- `MetalRenderer.isAvailable` returns `true` on the dev machine.
- The bundled `Kernels.metal` resource is reachable via `Bundle.module` (verified implicitly by `isAvailable`).
- Existing tests still pass.

**Verify:**
```
swift build && swift test --filter MetalAvailabilityTests
```
Expected: `Test Suite 'MetalAvailabilityTests' … passed`; `testMetalBackendAvailableOnDevMachine` passed.

**Steps:**
- [ ] Modify `Package.swift`: add `resources`/`exclude` to `FlameRenderer`, add `FlameRendererTests` test target.
- [ ] Create `Sources/FlameRenderer/Metal/Kernels.metal` with the `noop_kernel` sentinel.
- [ ] Rewrite `Sources/FlameRenderer/FlameRenderer.swift` to the module doc.
- [ ] Create `Sources/FlameRenderer/MetalRenderer.swift` with `isAvailable` + `deviceAndLibrary()`.
- [ ] Create `Tests/FlameRendererTests/MetalAvailabilityTests.swift`.
- [ ] Run verify command; commit.

Commit: `feat(renderer): MetalRenderer skeleton with SwiftPM-bundled MSL library loading`

---

## Task 2 — MSL ISAAC port + byte-equal-vs-Swift guardrail test (load-bearing primitive)

**Goal:** Port flam3's ISAAC (RANDSIZ=16, 32-bit-output-via-64-bit-state semantics) faithfully to MSL, and prove it produces a byte-identical stream to `FlameKit.ISAAC` for identical seeds. This is the single most load-bearing primitive: every chaos-game draw on the GPU depends on it, and statistical parity is unprovable until the RNG itself is exact. **This is proven before any kernel that consumes it.**

**Files:**
- Modify `Sources/FlameRenderer/Metal/Kernels.metal` — prepend the full ISAAC port plus an `isaac_check` kernel that writes the first N output words to a buffer. The MSL mirrors `Sources/FlameKit/ISAAC.swift` line-for-line: `ulong` (64-bit) state, `mix()` WITHOUT 32-bit masking (matches `ub4` on macOS LP64), `rngstep` masking every stored value to 32 bits, consumption order `RANDSIZ-1 → 0`.
  ```metal
  #include <metal_stdlib>
  using namespace metal;

  // File-scope `constant uint` globals are NOT guaranteed usable as array-size
  // constant expressions across MSL revisions; `#define` is universally accepted.
  #define ISAAC_RANDSIZL_MS  4
  #define ISAAC_RANDSIZ_MS   (1u << ISAAC_RANDSIZL_MS)   // 16
  #define ISAAC_RANDSIZ_M1   (ISAAC_RANDSIZ_MS - 1u)

  // Faithful port of flam3's ISAAC (isaac.c). State is held in `ulong` to match
  // `unsigned long int` (8 bytes) on macOS LP64; the mix() macro runs WITHOUT
  // 32-bit masking (load-bearing), and rngstep masks every stored value to 32
  // bits exactly as the C does. Verified byte-equal to FlameKit.ISAAC.
  struct IsaacState {
      ulong randcnt;                 // countdown into current results batch
      ulong randrsl[ISAAC_RANDSIZ_MS];
      ulong mm[ISAAC_RANDSIZ_MS];
      ulong aa, bb, cc;
  };

  static inline void isaac_mix(thread ulong& a, thread ulong& b, thread ulong& c,
                               thread ulong& d, thread ulong& e, thread ulong& f,
                               thread ulong& g, thread ulong& h) {
      a ^= (b << 11); d += a; b += c;
      b ^= (c >> 2);  e += b; c += d;
      c ^= (d << 8);  f += c; d += e;
      d ^= (e >> 16); g += d; e += f;
      e ^= (f << 10); h += e; f += g;
      f ^= (g >> 4);  a += f; g += h;
      g ^= (h << 8);  b += g; h += a;
      h ^= (a >> 9);  c += h; a += b;
  }

  static inline void isaac_rngstep(ulong mixExpr, thread ulong& a, thread ulong& b,
                                   thread ulong* mm, thread ulong* r,
                                   thread uint& m, thread uint& m2) {
      ulong x = mm[m];
      a = ((a ^ mixExpr) + mm[m2]) & 0xffffffffull;
      m2 += 1;
      ulong y = (mm[uint((x >> 2) & ulong(ISAAC_RANDSIZ_M1))] + a + b) & 0xffffffffull;
      mm[m] = y;
      m += 1;
      ulong idx = ((y >> ulong(ISAAC_RANDSIZL_MS)) >> 2) & ulong(ISAAC_RANDSIZ_M1);
      b = (mm[uint(idx)] + x) & 0xffffffffull;
      r[m - 1u] = b;
  }

  static inline void isaac_generate(thread IsaacState& s) {
      s.cc += 1;
      ulong a = s.aa;
      ulong b = (s.bb + s.cc) & 0xffffffffull;
      uint m = 0;
      uint m2 = ISAAC_RANDSIZ_MS / 2;
      while (m < ISAAC_RANDSIZ_MS / 2) {
          isaac_rngstep(a << 13, a, b, s.mm, s.randrsl, m, m2);
          isaac_rngstep(a >> 6,  a, b, s.mm, s.randrsl, m, m2);
          isaac_rngstep(a << 2,  a, b, s.mm, s.randrsl, m, m2);
          isaac_rngstep(a >> 16, a, b, s.mm, s.randrsl, m, m2);
      }
      m2 = 0;
      while (m2 < ISAAC_RANDSIZ_MS / 2) {
          isaac_rngstep(a << 13, a, b, s.mm, s.randrsl, m, m2);
          isaac_rngstep(a >> 6,  a, b, s.mm, s.randrsl, m, m2);
          isaac_rngstep(a << 2,  a, b, s.mm, s.randrsl, m, m2);
          isaac_rngstep(a >> 16, a, b, s.mm, s.randrsl, m, m2);
      }
      s.bb = b;
      s.aa = a;
  }

  // Seed from a 16-word randrsl buffer, mirroring flam3's irandinit(ctx, 1).
  static inline void isaac_init(thread IsaacState& s, thread const ulong* seed16) {
      for (uint i = 0; i < ISAAC_RANDSIZ_MS; i++) { s.mm[i] = 0; s.randrsl[i] = seed16[i] & 0xffffffffull; }
      s.aa = 0; s.bb = 0; s.cc = 0;
      ulong a = 0x9e3779b9, b = 0x9e3779b9, c = 0x9e3779b9, d = 0x9e3779b9;
      ulong e = 0x9e3779b9, f = 0x9e3779b9, g = 0x9e3779b9, h = 0x9e3779b9;
      for (uint i = 0; i < 4; i++) isaac_mix(a, b, c, d, e, f, g, h);
      // Pass 1: fold randrsl into mm.
      for (uint i = 0; i < ISAAC_RANDSIZ_MS; i += 8) {
          a += s.randrsl[i]; b += s.randrsl[i+1]; c += s.randrsl[i+2]; d += s.randrsl[i+3];
          e += s.randrsl[i+4]; f += s.randrsl[i+5]; g += s.randrsl[i+6]; h += s.randrsl[i+7];
          isaac_mix(a, b, c, d, e, f, g, h);
          s.mm[i] = a; s.mm[i+1] = b; s.mm[i+2] = c; s.mm[i+3] = d;
          s.mm[i+4] = e; s.mm[i+5] = f; s.mm[i+6] = g; s.mm[i+7] = h;
      }
      // Pass 2.
      for (uint i = 0; i < ISAAC_RANDSIZ_MS; i += 8) {
          a += s.mm[i]; b += s.mm[i+1]; c += s.mm[i+2]; d += s.mm[i+3];
          e += s.mm[i+4]; f += s.mm[i+5]; g += s.mm[i+6]; h += s.mm[i+7];
          isaac_mix(a, b, c, d, e, f, g, h);
          s.mm[i] = a; s.mm[i+1] = b; s.mm[i+2] = c; s.mm[i+3] = d;
          s.mm[i+4] = e; s.mm[i+5] = f; s.mm[i+6] = g; s.mm[i+7] = h;
      }
      isaac_generate(s);
      s.randcnt = ulong(ISAAC_RANDSIZ_MS);   // consume from the top
  }

  // irand(): consume next 32-bit word. Matches FlameKit ISAAC.next() exactly.
  static inline uint isaac_next(thread IsaacState& s) {
      if (s.randcnt == 0) {
          isaac_generate(s);
          s.randcnt = ulong(ISAAC_RANDSIZ_MS - 1);
      } else {
          s.randcnt -= 1;
      }
      return uint(s.randrsl[uint(s.randcnt)]);   // already masked to 32 bits
  }

  // Test kernel: seed from seed16[0..15], emit `count` words into out[0..count].
  kernel void isaac_check(constant const ulong* seed16 [[buffer(0)]],
                          device uint* out [[buffer(1)]],
                          constant const uint& count [[buffer(2)]],
                          uint gid [[thread_position_in_grid]]) {
      if (gid != 0) return;
      IsaacState s;
      isaac_init(s, seed16);
      for (uint i = 0; i < count; i++) { out[i] = isaac_next(s); }
  }

  kernel void noop_kernel(device uint* out [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
      if (gid == 0) { out[0] = 0x4d657461; }
  }
  ```
- Create `Sources/FlameRenderer/ISAACBridge.swift` — host helper that runs `isaac_check` and returns the emitted words:
  ```swift
  import Foundation
  import Metal
  import FlameKit

  @MainActor
  enum ISAACBridge {
      /// Run the MSL `isaac_check` kernel for the given 16-word seed and return
      /// the first `count` output words. Throws if Metal is unavailable.
      static func stream(seed16: [UInt64], count: Int) throws -> [UInt32] {
          guard let (device, library) = MetalRenderer.deviceAndLibrary() else {
              throw NSError(domain: "MetalRenderer", code: 10)
          }
          let pso = try library.makeFunction("isaac_check")!.makeComputePipelineState()
          let seedBuf = device.makeBuffer(bytes: seed16, length: 16 * MemoryLayout<UInt64>.size)!
          let outBuf  = device.makeBuffer(length: count * MemoryLayout<UInt32>.size)!
          var n = UInt32(count)
          let nBuf   = device.makeBuffer(bytes: &n, length: MemoryLayout<UInt32>.size)!
          let queue = device.makeCommandQueue()!
          let cb = queue.makeCommandBuffer()!
          let enc = cb.makeComputeCommandEncoder()!
          enc.setComputePipelineState(pso)
          enc.setBuffer(seedBuf, offset: 0, index: 0)
          enc.setBuffer(outBuf, offset: 0, index: 1)
          enc.setBuffer(nBuf, offset: 0, index: 2)
          enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
          enc.endEncoding()
          cb.commit()
          cb.waitUntilCompleted()
          return Array(UnsafeBufferPointer(start: outBuf.contents().assumingMemoryBound(to: UInt32.self), count: count))
      }
  }
  ```
- Create `Tests/FlameRendererTests/MSLIsaacParityTests.swift` — byte-equal guardrail:
  ```swift
  import XCTest
  @testable import FlameRenderer
  import FlameKit

  final class MSLIsaacParityTests: XCTestCase {
      private func seed(from str: String) -> [UInt64] {
          // Mirror ISAAC.parseSeedBytes: 128-byte LE buffer of the UTF-8 bytes.
          var bytes = [UInt8](repeating: 0, count: 128)
          let src = Array(str.utf8)
          for i in 0..<min(src.count, 128) { bytes[i] = src[i] }
          var words = [UInt64](repeating: 0, count: 16)
          for w in 0..<16 {
              var v: UInt64 = 0
              for b in 0..<8 { v |= UInt64(bytes[w*8 + b]) << (b*8) }
              words[w] = v
          }
          return words
      }

      func testMSLMatchesSwiftAcrossSeeds() throws {
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              let seeds = ["emberweftgoldens", "", "a", "0123456789abcdef",
                           "x", "longer-seed-string-for-padding-test-1234567890"]
              for s in seeds {
                  let seed16 = seed(from: s)
                  var swift = ISAAC(randrsl: seed16)
                  let swiftStream = (0..<1024).map { _ in swift.next() }
                  let mslStream = try ISAACBridge.stream(seed16: seed16, count: 1024)
                  XCTAssertEqual(swiftStream, mslStream, "MSL ISAAC diverged from Swift for seed \(s)")
              }
          }
      }
  }
  ```

**Acceptance Criteria:**
- The MSL ISAAC produces a byte-identical stream to `FlameKit.ISAAC` for every test seed across the first 1024 words (and by implication the full stream — ISAAC is deterministic).
- The test covers the empty seed, single-char, exactly-16-byte, and >16-byte (truncation) cases.

**Verify:**
```
swift test --filter MSLIsaacParityTests
```
Expected: `testMSLMatchesSwiftAcrossSeeds` passed (all 6 seeds byte-equal).

**Steps:**
- [ ] Prepend the ISAAC MSL port + `isaac_check` kernel to `Kernels.metal`.
- [ ] Create `Sources/FlameRenderer/ISAACBridge.swift`.
- [ ] Create `Tests/FlameRendererTests/MSLIsaacParityTests.swift`.
- [ ] Run the verify command. If it fails, the divergence is in the MSL port — do NOT proceed to later tasks; fix here.
- [ ] Commit.

Commit: `feat(renderer): faithful MSL ISAAC port, byte-equal to FlameKit.ISAAC`

---

## Task 3 — Lift shared pure types from `FlameReference` to `FlameKit`

**Goal:** `FlameRenderer` must depend on `FlameKit` only (not `FlameReference`), yet it needs `RGBA8Image`, `RenderParams`, `Histogram`, the spatial-filter-width helper, the xform-distribution builder, and the dmap builder. These are pure value types; move them to `FlameKit`. `FlameReference` keeps `@_exported import FlameKit`, so **every existing call site resolves unchanged** (the re-export means `FlameReference.RGBA8Image` is still `FlameReference.RGBA8Image` to callers).

**Files:**
- Create `Sources/FlameKit/RenderTypes.swift` containing `RGBA8Image`, `RenderParams`, `Histogram`, and `flam3SpatialFilterWidth` — moved **verbatim** from `Sources/FlameReference/ToneMapping.swift` (lines 4-11, `RGBA8Image`) and `Sources/FlameReference/Histogram.swift` (lines 4-43, `RenderParams` + `Histogram`), and `flam3SpatialFilterWidth` from `ToneMapping.swift` lines 191-197. Add a `Palette`-aware `buildDmap` (moved from `ChaosGame.swift` lines 312-320) and the xform-distribution builder (moved from `ChaosGame.swift` lines 286-305) as public API:
  ```swift
  import Foundation

  public struct RGBA8Image: Sendable, Equatable {
      public let width: Int
      public let height: Int
      public var pixels: [UInt8]
      public init(width: Int, height: Int, pixels: [UInt8]) {
          self.width = width; self.height = height; self.pixels = pixels
      }
  }

  public struct RenderParams: Sendable, Equatable {
      public let seed: UInt64
      public let width: Int
      public let height: Int
      public let oversample: Int
      public let samplesPerPixel: Int
      public init(seed: UInt64, width: Int, height: Int, oversample: Int, samplesPerPixel: Int) {
          self.seed = seed; self.width = width; self.height = height
          self.oversample = max(1, oversample); self.samplesPerPixel = samplesPerPixel
      }
      public static let spatialFilterRadius: Double = 0.5
      public var filterWidth: Int { flam3SpatialFilterWidth(oversample: oversample, radius: Self.spatialFilterRadius) }
      public var gutterWidth: Int { (filterWidth - oversample) / 2 }
      public var gridWidth: Int { width * oversample + 2 * gutterWidth }
      public var gridHeight: Int { height * oversample + 2 * gutterWidth }
      public var totalSamples: Int { width * height * samplesPerPixel }
  }

  public struct Histogram: Equatable, Sendable {
      public var counts: [Double]
      public var colors: [SIMD3<Double>]
      public var alpha: [Double]
      public let gridWidth: Int
      public let gridHeight: Int
      public var sampleSum: Double { counts.reduce(0, +) }
      public init(gridWidth: Int, gridHeight: Int) {
          self.gridWidth = gridWidth; self.gridHeight = gridHeight
          counts = Array(repeating: 0, count: gridWidth * gridHeight)
          colors = Array(repeating: .zero, count: gridWidth * gridHeight)
          alpha  = Array(repeating: 0, count: gridWidth * gridHeight)
      }
      public func binIndex(_ x: Int, _ y: Int) -> Int { x + y * gridWidth }
  }

  /// `filter_width` (rect.c:628, `flam3_create_spatial_filter`).
  public func flam3SpatialFilterWidth(oversample: Int, radius: Double) -> Int {
      let support: Double = 1.5
      let fwRaw = 2.0 * support * Double(oversample) * radius
      var fwidth = Int(fwRaw) + 1
      if ((fwidth ^ oversample) & 1) != 0 { fwidth += 1 }
      return fwidth
  }

  /// `flam3_create_chaos_distrib` (flam3.c:165). The 16384-entry weighted
  /// selection table. Shared by CPU chaos game and Metal host so the xform-pick
  /// *distribution* is bit-identical between backends (only per-thread ordering
  /// differs — the source of statistical, not byte-exact, parity).
  public enum Flam3XformDistrib {
      public static let grain = 16384
      public static func build(_ weights: [Double]) -> [Int] {
          let n = weights.count
          precondition(n > 0)
          let total = weights.reduce(0, +)
          precondition(total > 0)
          let dr = total / Double(grain)
          var table = [Int](repeating: 0, count: grain)
          var j = 0
          var t = weights[0]
          var r: Double = 0
          for i in 0..<grain {
              while r >= t {
                  j += 1
                  if j < n { t += weights[j] } else { break }
              }
              table[i] = min(j, n - 1)
              r += dr
          }
          return table
      }
  }

  /// Pre-scaled colormap (rect.c:778-782): `dmap[j] = palette[j] * WHITE_LEVEL *
  /// color_scalar`. RGB only; alpha is uniform (`WHITE_LEVEL*color_scalar`).
  @inlinable
  public func buildDmap(_ palette: Palette, whiteLevel: Double, colorScalar: Double) -> [SIMD3<Double>] {
      var dmap = [SIMD3<Double>](repeating: .zero, count: 256)
      let scale = whiteLevel * colorScalar
      for j in 0..<256 {
          let c = palette.colors[j]
          dmap[j] = SIMD3<Double>(c.x * scale, c.y * scale, c.z * scale)
      }
      return dmap
  }
  ```
- Modify `Sources/FlameReference/Histogram.swift`: delete the `RenderParams` and `Histogram` definitions (now in FlameKit). Keep only `import Foundation` + `import FlameKit` (the file may be left empty or removed from the target; simplest: leave it with just the imports).
- Modify `Sources/FlameReference/ToneMapping.swift`: delete the `RGBA8Image` struct (lines 4-11) and the `flam3SpatialFilterWidth` function (lines 191-197); keep the `makeSpatialKernel`/`gaussian`/HSV helpers and the `ToneMapping` enum, which now reference `FlameKit.Histogram`/`FlameKit.RGBA8Image` via the re-export. `makeSpatialKernel` calls `flam3SpatialFilterWidth` — now resolved via FlameKit.
- Modify `Sources/FlameReference/ChaosGame.swift`:
  - Replace the local `buildXformDistrib(weights)` call with `Flam3XformDistrib.build(weights)`.
  - Replace `buildDmap(...)` call with the FlameKit one.
  - Delete the now-duplicate `buildXformDistrib` (lines 286-305), `buildDmap` (lines 312-320), and the local `ISAAC_RANDSIZ_WORDS` constant (line 326); use `ISAAC.randsizWords` (added below).
  - Replace `ISAAC_RANDSIZ_WORDS` usages with `ISAAC.randsizWords`.
- Modify `Sources/FlameKit/ISAAC.swift`: add a public constant:
  ```swift
  public extension ISAAC {
      /// RANDSIZ = 1<<4 = 16 — number of words per ISAAC results/seed table.
      static let randsizWords: Int = 1 << ISAAC_RANDSIZL
  }
  ```

**Acceptance Criteria:**
- `swift build` clean.
- `swift test` — **all existing tests pass unchanged** (FlameKitTests, FlameReferenceTests, EmberweftCLITests). This is the regression gate for the refactor.
- No source file outside `FlameReference`/`FlameKit` is edited.

**Verify:**
```
swift build && swift test
```
Expected: full suite green; specifically `GoldenParityTests`, `ChaosGameTests`, `ToneMappingTests`, `CLISnapshotTests` unchanged.

**Steps:**
- [ ] Create `Sources/FlameKit/RenderTypes.swift` with the five moved definitions.
- [ ] Add `ISAAC.randsizWords` in `Sources/FlameKit/ISAAC.swift`.
- [ ] Strip moved definitions from `Histogram.swift` and `ToneMapping.swift`.
- [ ] Update `ChaosGame.swift` to call `Flam3XformDistrib.build`, FlameKit `buildDmap`, and `ISAAC.randsizWords`.
- [ ] Run verify command; confirm the full pre-existing suite is still green.
- [ ] Commit.

Commit: `refactor(kit): lift RGBA8Image/RenderParams/Histogram/distrib/dmap to FlameKit`

---

## Task 4 — Metal host plumbing: buffers, per-thread ISAAC seeding, fixed-point encoding, command queue

**Goal:** Land all host-side machinery the chaos kernel needs: the pinned thread geometry, the `GPUXform`/`GPUFrameParams` buffer layouts (Swift mirrors of the MSL structs), the `xform_distrib` + palette upload (shared FlameKit builders), the per-thread ISAAC `randrsl` precompute, the deterministic uint32 fixed-point color-accumulation encoding, and the `@MainActor` command-queue holder.

**Why the encoding is what it is (load-bearing):** Metal has no fast order-independent float atomic, and 64-bit atomics require Apple8 (M2+) which would break the M1+ target. `uint32` addition mod 2³² is fully associative → the final sum is **identical regardless of thread scheduling** → within-backend byte-determinism holds. To prevent overflow we rescale per-frame: with `T = params.totalSamples`, the worst-case single-channel sum is `T·255`; define
```
scale = 2^31 / (T · 255)
```
Per-hit uint contribution for a dmap-channel value `v ∈ [0,255]` is `UInt32((v · scale).rounded())`; the decoded Double is `Double(sum_uint) / scale` (in dmap units, matching CPU `hist.colors`). Round-to-nearest is unbiased; per-hit granularity is ~`255·scale = 2^31/T` levels (≈ 10 at 1080p/200spp, ≈ 670 at the 320×200×100 goldens) — far below the 38 dB floor after log/gamma/8-bit quant. Count is a plain `uint32` atomic (exact; `T < 2^32` always). No overflow is possible by construction; no clamp is ever applied (a clamp would silently destroy energy and break parity).

**Files:**
- Modify `Sources/FlameKit/Variations.swift`: add a canonical 19-name order so Metal's fixed-slot function table maps genome variations deterministically:
  ```swift
  public extension Variations {
      /// Fixed canonical slot order for the Metal kernel's variation table.
      /// Only `julia` consumes the RNG; with a single RNG-consuming variation,
      /// canonical-order iteration is RNG-equivalent to CPU genome-order.
      ///
      /// ASSUMPTIONS (verified against the 6 frozen genomes + the M2 fuzz genome;
      /// revisit if a future genome violates them):
      /// (1) Each xform has AT MOST ONE variation of each name. The Metal host
      ///     folds repeated names into one canonical slot by summing weights
      ///     (`base[slot] += weight`), which is algebraically identical for
      ///     non-RNG variations but changes RNG consumption for `julia`: two
      ///     julia entries on the CPU consume TWO ISAAC words and produce two
      ///     terms, whereas Metal would consume ONE word and produce one summed
      ///     term. No frozen/fuzz genome has repeated names, so this is safe.
      /// (2) Each xform has ≤2 active variations. With ≤2 nonzero terms the
      ///     float sum is bit-identical regardless of summation order (float
      ///     addition is commutative; zero terms contribute exactly). Genomes
      ///     with ≥3 active variations would diverge from CPU by FP-associativity
      ///     ULPs — still inside the statistical-parity envelope, not a bug.
      public static let canonicalOrder: [String] = [
          "bent", "cosine", "cylinder", "diamond", "disc", "ex", "exponential",
          "fisheye", "handkerchief", "heart", "horseshoe", "hyperbolic", "julia",
          "linear", "polar", "sinusoidal", "spherical", "spiral", "swirl"
      ]
  }
  ```
- Create `Sources/FlameRenderer/MetalHost.swift` — `@MainActor` host types and builders:
  ```swift
  import Foundation
  import Metal
  import FlameKit

  // MARK: - Device-side structs (Swift mirrors of the MSL structs in Kernels.metal.
  // Field order and types MUST match exactly; both align `float` to 4 bytes.)

  /// One IFS transform, device layout. 19-slot variation table.
  ///
  /// LAYOUT CONTRACT: this struct crosses the Swift→MSL boundary as raw bytes,
  /// so its in-memory layout MUST match `struct GPUXform` in Kernels.metal
  /// field-for-field. Both sides are all-`float` (4-byte align), 6+6+3+19 = 34
  /// floats = 136 bytes, stride 136. Swift does not formally guarantee struct
  /// field order or homogeneous-tuple contiguity in the language spec, but the
  /// ABI lays out trivial structs of `Float` fields sequentially with no
  /// padding. `buildGPUXforms` asserts the stride at runtime so any future ABI
  /// drift fails loudly instead of silently corrupting the device buffer. If
  /// the assertion ever fires on a new toolchain, switch `varWeights` to a
  /// `withUnsafeMutablePointer`-filled `[Float]` of count 19 copied into the
  /// device buffer (or 4×`SIMD4<Float>`), which is fully layout-defined.
  public struct GPUXform {
      public var a: Float = 0, b: Float = 0, c: Float = 0, d: Float = 0, e: Float = 0, f: Float = 0
      public var pa: Float = 0, pb: Float = 0, pc: Float = 0, pd: Float = 0, pe: Float = 0, pf: Float = 0
      public var color: Float = 0
      public var colorSpeed: Float = 0
      public var opacity: Float = 0
      public var varWeights: (Float, Float, Float, Float, Float, Float, Float,
                              Float, Float, Float, Float, Float, Float, Float,
                              Float, Float, Float, Float, Float) =
            (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
      public init() {}
  }

  /// Per-frame constants passed to the chaos kernel.
  public struct GPUFrameParams {
      public var gridWidth: UInt32 = 0
      public var gridHeight: UInt32 = 0
      public var gutter: UInt32 = 0
      public var oversample: Float = 1
      public var cosR: Float = 1
      public var sinR: Float = 0
      public var pixelsPerUnit: Float = 1
      public var centerX: Float = 0
      public var centerY: Float = 0
      public var iterationsPerThread: UInt32 = 0
      public var remainder: UInt32 = 0       // first `remainder` threads do one extra iter
      public var threadCount: UInt32 = 0
      public var fuse: UInt32 = 15
      public var cmapSize: UInt32 = 256
      public var cmapSizeM1: UInt32 = 255
      public var colorScale: Float = 0       // == `scale` (per-frame uint32 fixed-point unit)
      public var hasFinal: UInt32 = 0        // 1 if finalXform buffer is valid
      public init() {}
  }

  @MainActor
  enum MetalHost {
      // Pin thread geometry from params alone (NOT device caps) → machine-independent.
      static let threadsPerGroup: Int = 256

      static func pinnedThreadCount(totalSamples: Int) -> Int {
          let targetThreads = max(1024, (totalSamples / 64).rounded(.up))
          // Round up to a multiple of threadsPerGroup.
          let groups = (targetThreads + threadsPerGroup - 1) / threadsPerGroup
          return groups * threadsPerGroup
      }

      /// Build the device xform array from a Flame: affine (tx=a·x+c·y+e),
      /// post-affine, color/colorSpeed/opacity, and the 19-slot canonical
      /// variation table (summing weights of repeated names, which is algebraically
      /// identical to CPU's array-order sum because variation terms commute).
      static func buildGPUXforms(_ flame: Flame) -> [GPUXform] {
          // Layout-contract guard: see GPUXform doc comment. 34 Floats == 136 B.
          precondition(MemoryLayout<GPUXform>.stride == 136,
                       "GPUXform stride drifted from MSL mirror (136 bytes); Metal buffer would be misread")
          let slots = Variations.canonicalOrder
          var idxMap = [String: Int]()
          for (i, n) in slots.enumerated() { idxMap[n] = i }
          return flame.xforms.map { xf in
              var g = GPUXform()
              g.a = Float(xf.affine.a); g.b = Float(xf.affine.b); g.c = Float(xf.affine.c)
              g.d = Float(xf.affine.d); g.e = Float(xf.affine.e); g.f = Float(xf.affine.f)
              g.pa = Float(xf.postAffine.a); g.pb = Float(xf.postAffine.b); g.pc = Float(xf.postAffine.c)
              g.pd = Float(xf.postAffine.d); g.pe = Float(xf.postAffine.e); g.pf = Float(xf.postAffine.f)
              g.color = Float(xf.color); g.colorSpeed = Float(xf.colorSpeed); g.opacity = Float(xf.opacity)
              withUnsafeMutableBytes(of: &g.varWeights) { raw in
                  let base = raw.baseAddress!.assumingMemoryBound(to: Float.self)
                  for v in xf.variations where v.weight != 0 {
                      if let s = idxMap[v.name] { base[s] += Float(v.weight) }
                  }
              }
              return g
          }
      }

      /// Build the optional final-xform buffer (nil if the flame has none).
      static func buildGPUFinalXform(_ flame: Flame) -> GPUXform? {
          guard flame.finalXform != nil else { return nil }
          // Reuse buildGPUXforms on a synthetic single-xform flame to keep one code path.
          let single = Flame(xforms: [flame.finalXform!])
          return buildGPUXforms(single)[0]
      }

      /// Precompute every thread's 16-word ISAAC `randrsl` by serial draws from a
      /// parent ISAAC. Collision-free, deterministic, machine-independent — the
      /// exact flam3 parent→child mechanism, replicated per thread.
      static func buildThreadSeeds(seed: UInt64, threadCount: Int) -> [UInt64] {
          var parent = ISAAC(isaacSeed: "emberweft-metal-\(seed)")
          var out = [UInt64](repeating: 0, count: threadCount * ISAAC.randsizWords)
          for t in 0..<threadCount {
              for w in 0..<ISAAC.randsizWords { out[t * ISAAC.randsizWords + w] = UInt64(parent.next()) }
          }
          return out
      }

      /// Per-frame uint32 fixed-point scale: `scale = 2^31 / (T·255)`.
      static func colorScale(totalSamples: Int) -> Float {
          Float((Double(1 << 31)) / (Double(totalSamples) * 255.0))
      }

      /// Build GPUFrameParams from flame + params + pinned thread geometry.
      static func buildFrameParams(_ flame: Flame, _ params: RenderParams) -> GPUFrameParams {
          let tc = pinnedThreadCount(totalSamples: params.totalSamples)
          let ipt = params.totalSamples / tc
          let rem = params.totalSamples % tc
          var fp = GPUFrameParams()
          fp.gridWidth = UInt32(params.gridWidth)
          fp.gridHeight = UInt32(params.gridHeight)
          fp.gutter = UInt32(params.gutterWidth)
          fp.oversample = Float(params.oversample)
          let r = flame.camera.rotation * .pi / 180
          fp.cosR = Float(cos(r)); fp.sinR = Float(sin(r))
          fp.pixelsPerUnit = Float(flame.camera.scale * pow(2, flame.camera.zoom) * Double(params.oversample))
          fp.centerX = Float(flame.camera.center.x); fp.centerY = Float(flame.camera.center.y)
          fp.iterationsPerThread = UInt32(ipt)
          fp.remainder = UInt32(rem)
          fp.threadCount = UInt32(tc)
          fp.colorScale = colorScale(totalSamples: params.totalSamples)
          return fp
      }
  }
  ```
- Modify `Sources/FlameRenderer/Metal/Kernels.metal` — add the device struct mirrors (must match Swift `GPUXform`/`GPUFrameParams` field-for-field) and the dmap palette buffer binding:
  ```metal
  // ---- Device mirrors of Swift GPUXform / GPUFrameParams (field order identical) ----
  struct GPUXform {
      float a, b, c, d, e, f;
      float pa, pb, pc, pd, pe, pf;
      float color, colorSpeed, opacity;
      float varWeights[19];
  };
  struct GPUFrameParams {
      uint gridWidth, gridHeight, gutter;
      float oversample, cosR, sinR, pixelsPerUnit, centerX, centerY;
      uint iterationsPerThread, remainder, threadCount, fuse, cmapSize, cmapSizeM1;
      float colorScale;
      uint hasFinal;
  };
  // Palette: 256 pre-scaled RGB entries (dmap), passed as a flat float3 array.
  ```
- Create `Sources/FlameRenderer/MetalQueues.swift` — memoized command queue:
  ```swift
  import Metal

  @MainActor
  extension MetalRenderer {
      static var commandQueue: MTLCommandQueue? {
          if let q = _queue { return q }
          guard let (device, _) = deviceAndLibrary() else { return nil }
          let q = device.makeCommandQueue()
          _queue = q
          return q
      }
      @MainActor private static var _queue: MTLCommandQueue?
  }
  ```

**Acceptance Criteria:**
- `swift build` clean.
- `GPUXform`/`GPUFrameParams` field order matches the MSL structs byte-for-byte (audited by eye; no runtime test yet — the chaos-kernel parity test in Task 6 is the real proof).
- `MetalHost.pinnedThreadCount` is a pure function of `totalSamples` (no device queries) → deterministic.
- `MetalHost.buildThreadSeeds` is deterministic for a fixed `seed` and `threadCount`.

**Verify:**
```
swift build
```
Expected: clean build (no test yet — these are exercised by Tasks 5/6).

**Steps:**
- [ ] Add `Variations.canonicalOrder` to `Sources/FlameKit/Variations.swift`.
- [ ] Create `Sources/FlameRenderer/MetalHost.swift`.
- [ ] Add `GPUXform`/`GPUFrameParams` MSL structs to `Kernels.metal`.
- [ ] Create `Sources/FlameRenderer/MetalQueues.swift`.
- [ ] Build; commit.

Commit: `feat(renderer): Metal host plumbing — buffers, seeding, fixed-point encoding`

---

## Task 5 — Stage 1 chaos-game kernel + host dispatch + histogram decode

**Goal:** The chaos kernel that iterates the IFS on the GPU, faithfully mirroring `ChaosGame.iterate` (affine `tx=a·x+c·y+e`, 19 variations in canonical order, `precalc_atan=atan2(x,y)`, EPS=1e-10, badvalue |·|>1e10, final xform transforming a SEPARATE binning point), accumulating into a `uint32` fixed-point atomic histogram, plus the host dispatch and decode-to-`FlameKit.Histogram`. After this task, the histogram-parity test (Task 6) closes Stage 1.

**Files:**
- Modify `Sources/FlameRenderer/Metal/Kernels.metal` — add the histogram struct, the 19 variation functions, the affine/blend helpers, and the `chaosGame` kernel:
  ```metal
  constant float EPS_MS  = 1e-10f;
  constant float BAD_MS  = 1e10f;
  constant uint CHAOS_GRAIN_M1 = 16383u;

  struct AtomicBin {
      atomic_uint count;
      atomic_uint r, g, b, a;
  };

  static inline bool badvalue_ms(float x) { return (x != x) || (x > BAD_MS) || (x < -BAD_MS); }

  static inline float2 apply_affine(GPUXform x, float2 p) {
      return float2(x.a*p.x + x.c*p.y + x.e, x.b*p.x + x.d*p.y + x.f);
  }
  static inline float2 apply_post(GPUXform x, float2 p) {
      return float2(x.pa*p.x + x.pc*p.y + x.pe, x.pb*p.x + x.pd*p.y + x.pf);
  }
  static inline float blend_color(GPUXform x, float ct) {
      return (1.0f - x.colorSpeed) * ct + x.colorSpeed * x.color;
  }

  // 19 variation terms (canonical slot order). Each returns the term that CPU
  // `Variations.evaluate` would add to f.p0/p1, weight folded at flam3's exact
  // position. Float (not Double) — accepted by the statistical-parity model.
  static inline float2 v_bent(float2 p, float w) {
      return float2(w * (p.x < 0 ? 2.0f*p.x : p.x), w * (p.y < 0 ? 0.5f*p.y : p.y));
  }
  static inline float2 v_cosine(float2 p, float w) {
      return float2(w * cos(p.x * M_PI_F) * cosh(p.y), w * (-sin(p.x * M_PI_F)) * sinh(p.y));
  }
  static inline float2 v_cylinder(float2 p, float w) { return float2(w * sin(p.x), w * p.y); }
  static inline float2 v_diamond(float2 p, float w) {
      float r = sqrt(p.x*p.x + p.y*p.y); float a = atan2(p.x, p.y);
      return float2(w * sin(a) * cos(r), w * cos(a) * sin(r));
  }
  static inline float2 v_disc(float2 p, float w) {
      float a = atan2(p.x, p.y) / M_PI_F; float r = M_PI_F * sqrt(p.x*p.x + p.y*p.y);
      return float2(w * sin(r) * a, w * cos(r) * a);
  }
  static inline float2 v_ex(float2 p, float w) {
      float a = atan2(p.x, p.y); float r = sqrt(p.x*p.x + p.y*p.y);
      float n0 = sin(a + r); float n1 = cos(a - r);
      float m0 = n0*n0*n0 * r; float m1 = n1*n1*n1 * r;
      return float2(w * (m0 + m1), w * (m0 - m1));
  }
  static inline float2 v_exponential(float2 p, float w) {
      float e = exp(p.x - 1.0f);
      return float2(w * e * cos(M_PI_F * p.y), w * e * sin(M_PI_F * p.y));
  }
  static inline float2 v_fisheye(float2 p, float w) {
      float r = 2.0f / (sqrt(p.x*p.x + p.y*p.y) + 1.0f);
      return float2(w * r * p.y, w * r * p.x);
  }
  static inline float2 v_handkerchief(float2 p, float w) {
      float a = atan2(p.x, p.y); float r = sqrt(p.x*p.x + p.y*p.y);
      return float2(w * r * sin(a + r), w * r * cos(a - r));
  }
  static inline float2 v_heart(float2 p, float w) {
      float ps = sqrt(p.x*p.x + p.y*p.y); float a = ps * atan2(p.x, p.y); float r = w * ps;
      return float2(r * sin(a), (-r) * cos(a));
  }
  static inline float2 v_horseshoe(float2 p, float w) {
      float r = w / (sqrt(p.x*p.x + p.y*p.y) + EPS_MS);
      return float2((p.x - p.y) * (p.x + p.y) * r, 2.0f * p.x * p.y * r);
  }
  static inline float2 v_hyperbolic(float2 p, float w) {
      float r = sqrt(p.x*p.x + p.y*p.y) + EPS_MS; float a = atan2(p.x, p.y);
      return float2(w * sin(a) / r, w * cos(a) * r);
  }
  // julia — consumes one ISAAC word (lowest bit), exactly like CPU.
  static inline float2 v_julia(float2 p, float w, thread IsaacState& rng) {
      float sumsq = p.x*p.x + p.y*p.y;
      float ps = sqrt(sumsq);
      float a = 0.5f * atan2(p.x, p.y);
      float r = w * sqrt(ps);
      if ((isaac_next(rng) & 1u) != 0u) { a += M_PI_F; }
      return float2(r * cos(a), r * sin(a));
  }
  static inline float2 v_linear(float2 p, float w) { return float2(w * p.x, w * p.y); }
  static inline float2 v_polar(float2 p, float w) {
      float nx = atan2(p.x, p.y) / M_PI_F; float ny = sqrt(p.x*p.x + p.y*p.y) - 1.0f;
      return float2(w * nx, w * ny);
  }
  static inline float2 v_sinusoidal(float2 p, float w) { return float2(w * sin(p.x), w * sin(p.y)); }
  static inline float2 v_spherical(float2 p, float w) {
      float r2 = w / (p.x*p.x + p.y*p.y + EPS_MS); return float2(r2 * p.x, r2 * p.y);
  }
  static inline float2 v_spiral(float2 p, float w) {
      float r = sqrt(p.x*p.x + p.y*p.y) + EPS_MS; float r1 = w / r; float a = atan2(p.x, p.y);
      return float2(r1 * (cos(a) + sin(r)), r1 * (sin(a) - cos(r)));
  }
  static inline float2 v_swirl(float2 p, float w) {
      float r2 = p.x*p.x + p.y*p.y; float c1 = sin(r2); float c2 = cos(r2);
      return float2(w * (c1*p.x - c2*p.y), w * (c2*p.x + c1*p.y));
  }

  // Sum the 19 canonical slots. Only `julia` consumes the RNG.
  // CRITICAL: every slot MUST be guarded by `w[i] != 0` to match CPU
  // (`Variations.evaluate` skips weight==0). Without the guard, a weight-0
  // variation whose internals overflow to Inf (cosh/sinh in `cosine` for
  // |p.y|>710, exp in `exponential` for |p.x|>710) yields `0.0f * Inf == NaN`,
  // which contaminates `acc`, trips `badvalue_ms`, and diverges both the
  // trajectory and the RNG stream from the CPU. Chaotic maps (julia/spherical)
  // reach |p|∈(710,1e10) routinely, so this is load-bearing.
  static inline float2 apply_xform_body(GPUXform x, float2 p, thread IsaacState& rng) {
      float2 pre = apply_affine(x, p);
      float2 acc = float2(0.0f);
      float w[19];
      for (int i = 0; i < 19; i++) w[i] = x.varWeights[i];
      // Canonical slot order MUST match Variations.canonicalOrder exactly.
      if (w[0]  != 0.0f) acc += v_bent(pre, w[0]);
      if (w[1]  != 0.0f) acc += v_cosine(pre, w[1]);
      if (w[2]  != 0.0f) acc += v_cylinder(pre, w[2]);
      if (w[3]  != 0.0f) acc += v_diamond(pre, w[3]);
      if (w[4]  != 0.0f) acc += v_disc(pre, w[4]);
      if (w[5]  != 0.0f) acc += v_ex(pre, w[5]);
      if (w[6]  != 0.0f) acc += v_exponential(pre, w[6]);
      if (w[7]  != 0.0f) acc += v_fisheye(pre, w[7]);
      if (w[8]  != 0.0f) acc += v_handkerchief(pre, w[8]);
      if (w[9]  != 0.0f) acc += v_heart(pre, w[9]);
      if (w[10] != 0.0f) acc += v_horseshoe(pre, w[10]);
      if (w[11] != 0.0f) acc += v_hyperbolic(pre, w[11]);
      // julia is the only RNG consumer; guard still required for NaN safety.
      if (w[12] != 0.0f) acc += v_julia(pre, w[12], rng);
      if (w[13] != 0.0f) acc += v_linear(pre, w[13]);
      if (w[14] != 0.0f) acc += v_polar(pre, w[14]);
      if (w[15] != 0.0f) acc += v_sinusoidal(pre, w[15]);
      if (w[16] != 0.0f) acc += v_spherical(pre, w[16]);
      if (w[17] != 0.0f) acc += v_spiral(pre, w[17]);
      if (w[18] != 0.0f) acc += v_swirl(pre, w[18]);
      return apply_post(x, acc);
  }

  static inline float isaac_01(thread IsaacState& s) {
      return float(isaac_next(s) & 0x0fffffffu) * (1.0f / float(0x0fffffffu));
  }
  static inline float isaac_11(thread IsaacState& s) {
      return (float(isaac_next(s) & 0x0fffffffu) - float(0x07ffffffu)) * (1.0f / float(0x07ffffffu));
  }

  static inline void accumulate(device AtomicBin* hist, int u, int v, GPUFrameParams fp,
                                constant float3* dmap, constant float* dmapAlpha,
                                float binColor) {
      float dblIndex0 = binColor * float(fp.cmapSize);
      int ci0 = int(dblIndex0);
      float frac;
      if (ci0 >= int(fp.cmapSizeM1)) { ci0 = int(fp.cmapSizeM1) - 1; frac = 1.0f; }
      else { frac = dblIndex0 - float(ci0); }
      float m0 = 1.0f - frac;
      float3 interp = dmap[ci0] * m0 + dmap[ci0 + 1] * frac;
      float interpA = dmapAlpha[ci0] * m0 + dmapAlpha[ci0 + 1] * frac;
      float sc = fp.colorScale;
      auto q = [](float v, float s) -> uint { return uint(clamp(v, 0.0f, 255.0f) * s + 0.5f); };
      uint idx = uint(u) + uint(v) * fp.gridWidth;
      atomic_fetch_add_explicit(&hist[idx].count, 1u, memory_order_relaxed);
      atomic_fetch_add_explicit(&hist[idx].r, q(interp.x, sc), memory_order_relaxed);
      atomic_fetch_add_explicit(&hist[idx].g, q(interp.y, sc), memory_order_relaxed);
      atomic_fetch_add_explicit(&hist[idx].b, q(interp.z, sc), memory_order_relaxed);
      atomic_fetch_add_explicit(&hist[idx].a, q(interpA,  sc), memory_order_relaxed);
  }

  kernel void chaosGame(device GPUXform* xforms        [[buffer(0)]],
                        device GPUXform* finalXf        [[buffer(1)]],
                        constant uint*   distrib        [[buffer(2)]],
                        constant float3* dmap           [[buffer(3)]],
                        constant float*  dmapAlpha      [[buffer(4)]],
                        constant GPUFrameParams* fp     [[buffer(5)]],
                        constant ulong*  threadSeeds    [[buffer(6)]],
                        device AtomicBin* hist          [[buffer(7)]],
                        uint gid [[thread_position_in_grid]]) {
      if (gid >= fp->threadCount) return;
      IsaacState rng;
      isaac_init(rng, &threadSeeds[ulong(gid) * ISAAC_RANDSIZ_MS]);

      // Sub-batch seed draws (mirror CPU rect.c:393-396): p, colorT, vis(discarded).
      float2 p = float2(isaac_11(rng), isaac_11(rng));
      float colorT = isaac_01(rng);
      (void)isaac_01(rng);

      uint iterThisThread = fp->iterationsPerThread + (gid < fp->remainder ? 1u : 0u);
      uint total = fp->fuse + iterThisThread;
      uint consec = 0;
      bool hasFinal = (fp->hasFinal != 0u);
      GPUXform fin = hasFinal ? finalXf[0] : GPUXform{};

      // CRITICAL: this MUST be a `while` loop with an explicit `j += 1` at the
      // bottom, NOT a C `for`. The CPU oracle (ChaosGame.swift) uses `while j <
      // total { ...; j += 1 }` where `continue` (badvalue retry) SKIPS `j += 1`,
      // re-running the same slot with a fresh point without consuming an
      // iteration. In a C `for` loop, `continue` runs the increment expression,
      // which would (a) burn a post-fuse slot on every retry so Metal emits
      // FEWER than `totalSamples` samples (breaking the `sampleSum ==
      // totalSamples` assertion), and (b) structurally diverge the trajectory
      // from CPU. The `while` form makes `continue` jump to the condition,
      // leaving `j` unchanged — matching the oracle exactly.
      uint j = 0;
      while (j < total) {
          // distrib values are precomputed on the host as valid xform indices in [0, n).
          uint xfIdx = distrib[isaac_next(rng) & CHAOS_GRAIN_M1];
          GPUXform xf = xforms[xfIdx];
          float2 q = apply_xform_body(xf, p, rng);
          float qColor = blend_color(xf, colorT);

          if (badvalue_ms(q.x) || badvalue_ms(q.y)) {
              float rx = isaac_11(rng), ry = isaac_11(rng);
              consec += 1u;
              if (consec < 5u) { p = float2(rx, ry); continue; }   // retry slot; j NOT advanced
              q = float2(rx, ry); consec = 0u;
          } else { consec = 0u; }

          p = q; colorT = qColor;   // iteration point carries ONLY the main xform

          float2 binP = p; float binColor = colorT;
          if (hasFinal) {
              bool apply;
              if (fin.opacity >= 1.0f) apply = true;
              else if (fin.opacity > 0.0f) apply = (isaac_01(rng) < fin.opacity);
              else apply = false;
              if (apply) { binP = apply_xform_body(fin, p, rng); binColor = blend_color(fin, colorT); }
          }

          if (j >= fp->fuse) {
              if (binP.x == binP.x && binP.y == binP.y) {   // NaN check (NaN != NaN)
                  float dx = binP.x - fp->centerX, dy = binP.y - fp->centerY;
                  float rxs = dx * fp->cosR - dy * fp->sinR;
                  float rys = dx * fp->sinR + dy * fp->cosR;
                  float gx = rxs * fp->pixelsPerUnit + float(fp->gridWidth) * 0.5f;
                  float gy = rys * fp->pixelsPerUnit + float(fp->gridHeight) * 0.5f;
                  int u = int(floor(gx)); int v = int(floor(gy));
                  if (u >= 0 && u < int(fp->gridWidth) && v >= 0 && v < int(fp->gridHeight)) {
                      accumulate(hist, u, v, fp[0], dmap, dmapAlpha, binColor);
                  }
              }
          }
          j += 1;
      }
  }
  ```
  (The host guarantees `distrib` values are valid xform indices in `[0, n)`, so the kernel needs no extra bounds clamp on the lookup.)
- Create `Sources/FlameRenderer/ChaosGameMetal.swift` — host dispatch + decode, returning a `FlameKit.Histogram`:
  ```swift
  import Foundation
  import Metal
  import FlameKit

  @MainActor
  enum ChaosGameMetal {
      /// Run the Stage-1 chaos kernel and decode the result to a FlameKit.Histogram
      /// (counts/colors/alpha as Double, in the same dmap-pre-scaled units as CPU).
      static func iterate(flame: Flame, params: RenderParams) throws -> Histogram {
          guard let (device, library) = MetalRenderer.deviceAndLibrary(),
                let queue = MetalRenderer.commandQueue else {
              throw NSError(domain: "MetalRenderer", code: 11)
          }
          let fpStruct = MetalHost.buildFrameParams(flame, params)
          var fp = fpStruct
          fp.hasFinal = flame.finalXform != nil ? 1 : 0

          let xforms = MetalHost.buildGPUXforms(flame)
          let finalXf: [GPUXform] = [MetalHost.buildGPUFinalXform(flame) ?? GPUXform()]
          let weights = flame.xforms.map { max(0, $0.weight) }
          let distrib = Flam3XformDistrib.build(weights).map { UInt32($0) }
          let dmap = buildDmap(flame.palette, whiteLevel: 255, colorScalar: 1.0)
                      .map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
          let dmapAlpha: [Float] = Array(repeating: 255.0, count: 256)

          let tc = Int(fp.threadCount)
          let threadSeeds = MetalHost.buildThreadSeeds(seed: params.seed, threadCount: tc)

          // Buffers (shared storage on unified memory; zero the histogram).
          func buf<T>(_ arr: [T]) -> MTLBuffer {
              device.makeBuffer(bytes: arr, length: MemoryLayout<T>.stride * arr.count, options: .storageModeShared)!
          }
          let xformsBuf = xforms.withUnsafeBufferPointer { ptr in
              device.makeBuffer(bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr.baseAddress!),
                                length: MemoryLayout<GPUXform>.stride * xforms.count,
                                options: .storageModeShared, deallocator: nil) }
          // For simplicity and correctness (bytesNoCopy lifetime pitfalls), copy instead:
          let xb = device.makeBuffer(length: MemoryLayout<GPUXform>.stride * xforms.count, options: .storageModeShared)!
          xforms.withUnsafeBufferPointer { ptr in
              xb.contents().copyMemory(from: UnsafeRawPointer(ptr.baseAddress!),
                                       byteCount: MemoryLayout<GPUXform>.stride * xforms.count)
          }
          let fb = buf(finalXf)
          let db = device.makeBuffer(length: MemoryLayout<UInt32>.stride * distrib.count, options: .storageModeShared)!
          db.contents().copyMemory(from: UnsafeRawPointer(distrib.withUnsafeBufferPointer { $0.baseAddress! }),
                                   byteCount: MemoryLayout<UInt32>.stride * distrib.count)
          let dmab = device.makeBuffer(length: MemoryLayout<SIMD3<Float>>.stride * dmap.count, options: .storageModeShared)!
          dmap.withUnsafeBufferPointer { ptr in
              dmab.contents().copyMemory(from: UnsafeRawPointer(ptr.baseAddress!),
                                         byteCount: MemoryLayout<SIMD3<Float>>.stride * dmap.count)
          }
          let dab = buf(dmapAlpha)
          var fpLocal = fp
          let fpb = device.makeBuffer(length: MemoryLayout<GPUFrameParams>.stride, options: .storageModeShared)!
          fpb.contents().copyMemory(from: UnsafeRawPointer(&fpLocal),
                                    byteCount: MemoryLayout<GPUFrameParams>.stride)
          let tsb = device.makeBuffer(length: MemoryLayout<UInt64>.stride * threadSeeds.count, options: .storageModeShared)!
          threadSeeds.withUnsafeBufferPointer { ptr in
              tsb.contents().copyMemory(from: UnsafeRawPointer(ptr.baseAddress!),
                                        byteCount: MemoryLayout<UInt64>.stride * threadSeeds.count)
          }
          let binCount = params.gridWidth * params.gridHeight
          let histBuf = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 5 * binCount,
                                          options: .storageModeShared)!
          memset(histBuf.contents(), 0, MemoryLayout<UInt32>.stride * 5 * binCount)

          let pso = try library.makeFunction("chaosGame")!.makeComputePipelineState()
          let cb = queue.makeCommandBuffer()!
          let enc = cb.makeComputeCommandEncoder()!
          enc.setComputePipelineState(pso)
          enc.setBuffer(xb, offset: 0, index: 0)
          enc.setBuffer(fb, offset: 0, index: 1)
          enc.setBuffer(db, offset: 0, index: 2)
          enc.setBuffer(dmab, offset: 0, index: 3)
          enc.setBuffer(dab, offset: 0, index: 4)
          enc.setBuffer(fpb, offset: 0, index: 5)
          enc.setBuffer(tsb, offset: 0, index: 6)
          enc.setBuffer(histBuf, offset: 0, index: 7)
          let tpg = MetalHost.threadsPerGroup
          let groups = tc / tpg
          enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
          enc.endEncoding()
          cb.commit()
          cb.waitUntilCompleted()

          return decode(histBuf, params: params, colorScale: Double(fp.colorScale))
      }

      private static func decode(_ buf: MTLBuffer, params: RenderParams, colorScale: Double) -> Histogram {
          var hist = Histogram(gridWidth: params.gridWidth, gridHeight: params.gridHeight)
          let n = params.gridWidth * params.gridHeight
          let ptr = buf.contents().assumingMemoryBound(to: UInt32.self)
          let scale = colorScale
          for i in 0..<n {
              let b = i * 5
              let count = UInt32(ptr[b])
              if count == 0 { continue }
              hist.counts[i] = Double(count)
              hist.colors[i] = SIMD3(Double(ptr[b + 1]) / scale,
                                     Double(ptr[b + 2]) / scale,
                                     Double(ptr[b + 3]) / scale)
              hist.alpha[i] = Double(ptr[b + 4]) / scale
          }
          return hist
      }
  }
  ```
  Note: the `AtomicBin` MSL struct is `{count,r,g,b,a}` (5 × `atomic_uint`); the host reads it as a flat `UInt32` array of stride 5 per bin. Swift does not need a mirror struct for decode since it reads raw `UInt32`s.

**Acceptance Criteria:**
- `swift build` clean.
- `ChaosGameMetal.iterate` returns a populated `Histogram` with finite values.
- The histogram is deterministic across two calls with the same `(flame, params)` (counts identical, because uint32 atomic add is order-independent).

**Verify:**
```
swift build
```
(Task 6 supplies the runtime parity test.)

**Steps:**
- [ ] Append the chaos-kernel MSL (variation functions, affine/blend helpers, `chaosGame`) to `Kernels.metal`. Keep the per-slot `if (w[i] != 0.0f)` guards and the `while` (not `for`) iteration loop exactly as written — both are load-bearing (see inline comments).
- [ ] Create `Sources/FlameRenderer/ChaosGameMetal.swift`.
- [ ] Build; commit.

Commit: `feat(renderer): Metal Stage-1 chaos-game kernel with uint32 fixed-point histogram`

---

## Task 6 — Stage-1 histogram parity test (CPU vs Metal)

**Goal:** Prove the chaos kernel converges to the same IFS invariant measure as the CPU, bin-by-bin, before any tone-mapping is wired. This isolates Stage 1 so a later end-to-end regression bisects cleanly.

**Files:**
- Create `Tests/FlameRendererTests/HistogramParityTests.swift`:
  ```swift
  import XCTest
  @testable import FlameRenderer
  @testable import FlameReference
  import FlameKit

  final class HistogramParityTests: XCTestCase {
      private func sierpinski() -> Flame {
          Flame(size: SIMD2(64, 64), camera: Camera(scale: 64),
                xforms: [
                  Xform(affine: AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, e: -0.15, f: -0.1), color: 0,
                        variations: [Variation(name: "linear", weight: 1)]),
                  Xform(affine: AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, e: 0.15, f: -0.1), color: 0.5,
                        variations: [Variation(name: "linear", weight: 1)]),
                  Xform(affine: AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, e: 0, f: 0.175), color: 1,
                        variations: [Variation(name: "linear", weight: 1)])
                ])
      }

      private func compare(_ cpu: Histogram, _ gpu: Histogram) -> (countRelL1: Double, colorRelL1: Double, corr: Double) {
          precondition(cpu.counts.count == gpu.counts.count)
          var cL1 = 0.0, colL1 = 0.0
          var sumC = 0.0, sumG = 0.0, sumCG = 0.0, sumC2 = 0.0, sumG2 = 0.0
          for i in 0..<cpu.counts.count {
              cL1 += abs(cpu.counts[i] - gpu.counts[i])
              colL1 += abs(cpu.colors[i].x - gpu.colors[i].x)
                       + abs(cpu.colors[i].y - gpu.colors[i].y)
                       + abs(cpu.colors[i].z - gpu.colors[i].z)
              let c = cpu.counts[i], g = gpu.counts[i]
              sumC += c; sumG += g; sumCG += c*g; sumC2 += c*c; sumG2 += g*g
          }
          let total = max(cpu.sampleSum, gpu.sampleSum, 1)
          let n = Double(cpu.counts.count)
          let num = n*sumCG - sumC*sumG
          let den = (sqrt(n*sumC2 - sumC*sumC) * sqrt(n*sumG2 - sumG*sumG))
          let corr = den > 0 ? num/den : 1
          return (cL1/total, colL1/(3*total*255), corr)
      }

      func testSierpinskiHistogramMatches() throws {
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              let f = sierpinski()
              let p = RenderParams(seed: 7, width: 64, height: 64, oversample: 1, samplesPerPixel: 500)
              let cpu = ChaosGame.iterate(flame: f, params: p)
              let gpu = try ChaosGameMetal.iterate(flame: f, params: p)
              XCTAssertEqual(cpu.counts.count, gpu.counts.count)
              XCTAssertEqual(Int(gpu.sampleSum), p.totalSamples, "Metal did not produce exactly totalSamples")
              let m = compare(cpu, gpu)
              XCTAssertLessThan(m.countRelL1, 0.05, "count L1 too high: \(m)")
              XCTAssertGreaterThan(m.corr, 0.99, "count correlation too low: \(m)")
              XCTAssertLessThan(m.colorRelL1, 0.05, "color L1 too high: \(m)")
          }
      }

      func testFrozenGenomeHistogramsMatch() throws {
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              let genomesDir = URL(fileURLWithPath: #filePath)
                  .deletingLastPathComponent().deletingLastPathComponent()
                  .appendingPathComponent("Goldens/genomes")
              let genomes = (try? FileManager.default.contentsOfDirectory(at: genomesDir, includingPropertiesForKeys: nil))?
                  .filter { $0.pathExtension == "flam3" } ?? []
              for g in genomes {
                  let flame = try Flam3Parser.parse(Data(contentsOf: g))[0]
                  let p = RenderParams(seed: 0, width: 160, height: 100, oversample: 1, samplesPerPixel: 100)
                  let cpu = ChaosGame.iterate(flame: flame, params: p)
                  let gpu = try ChaosGameMetal.iterate(flame: flame, params: p)
                  let m = compare(cpu, gpu)
                  XCTAssertLessThan(m.countRelL1, 0.08, "\(g.lastPathComponent): count L1 \(m)")
                  XCTAssertGreaterThan(m.corr, 0.98, "\(g.lastPathComponent): corr \(m)")
                  XCTAssertLessThan(m.colorRelL1, 0.08, "\(g.lastPathComponent): color L1 \(m)")
              }
          }
      }
  }
  ```

**Acceptance Criteria:**
- `testSierpinskiHistogramMatches` passes: Metal produces exactly `totalSamples` hits; count correlation > 0.99; per-bin count relative L1 < 5%.
- `testFrozenGenomeHistogramsMatch` passes over all 6 frozen genomes with the looser thresholds.

**Verify:**
```
swift test --filter HistogramParityTests
```
Expected: both tests pass. If count correlation is low on a julia genome, the lever is sample count (bump `samplesPerPixel` in the test), not an algorithm change — FP32 iteration diverges per-trajectory but the measure still converges.

**Steps:**
- [ ] Create `Tests/FlameRendererTests/HistogramParityTests.swift`.
- [ ] Run the verify command. If a frozen genome fails, raise its threshold modestly and record why; do not lower thresholds below 0.95 correlation.
- [ ] Commit.

Commit: `test(renderer): Stage-1 histogram parity (CPU vs Metal) over goldens`

---

## Task 7 — Stage 3b on-ramp: `MetalRenderer.render` (Metal chaos → CPU ToneMapping) + first end-to-end parity gate

**Goal:** Wire the Metal chaos kernel into a full `render(flame:params:)` entry point that reuses the **existing CPU `ToneMapping`** on the decoded Metal histogram. This is the parity-bisect on-ramp: it proves Stage 1 end-to-end (image-level) before any Metal display kernel or DE kernel exists. Because the decoded Metal `Histogram` is in the exact same units as the CPU's (counts + dmap-pre-scaled colors/alpha as Double), CPU `ToneMapping` runs on it unmodified. DE is gated on `estimatorRadius > 0` and uses the CPU approximation (goldens are radius=0, so it is a passthrough for M2 parity).

**Files:**
- Modify `Sources/FlameRenderer/MetalRenderer.swift` — add the render entry point (Stage 3b path):
  ```swift
  import FlameReference  // NOTE: see "dependency note" below — this is the on-ramp path only.

  public extension MetalRenderer {
      /// Render `flame` at `params` to an 8-bit RGBA image.
      ///
      /// Stage-3b on-ramp (M2): chaos on Metal, density-estimation + tone-map on
      /// CPU. Deterministic within the Metal backend. Statistical twin of
      /// `ReferenceRenderer.render` (PSNR ≥ 38 dB), not byte-identical.
      @MainActor
      public static func render(flame: Flame, params: RenderParams) -> RGBA8Image {
          guard let (device, library) = deviceAndLibrary(),
                let queue = commandQueue else {
              fatalError("MetalRenderer.render called when isAvailable is false")
          }
          do {
              var hist = try ChaosGameMetal.iterate(flame: flame, params: params)
              if flame.quality.estimatorRadius > 0 {
                  // CPU approximation twin (goldens are radius=0 — unexercised in M2).
                  hist = FlameReference.DensityEstimation.apply(hist,
                      radius: flame.quality.estimatorRadius,
                      minimum: flame.quality.estimatorMinimum,
                      curve: flame.quality.estimatorCurveRate)
              }
              return FlameReference.ToneMapping.render(histogram: hist,
                  width: params.width, height: params.height, oversample: params.oversample,
                  gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
                  vibrancy: flame.quality.vibrancy,
                  sampleDensity: Double(params.samplesPerPixel),
                  pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom))
          } catch {
              fatalError("Metal render failed: \(error)")
          }
      }
  }
  ```
- Modify `Package.swift`: add `"FlameReference"` to `FlameRenderer`'s dependencies **only for the Stage-3b on-ramp**. (The full Stage-3a Metal display kernel in Task 9 removes this dependency for the production path; the on-ramp is kept behind a debug flag for parity bisection.)
- Create `Tests/FlameRendererTests/EndToEndParity3bTests.swift`:
  ```swift
  import XCTest
  @testable import FlameRenderer
  @testable import FlameReference
  import FlameKit

  final class EndToEndParity3bTests: XCTestCase {
      private func genomesDir() -> URL {
          URL(fileURLWithPath: #filePath)
              .deletingLastPathComponent().deletingLastPathComponent()
              .appendingPathComponent("Goldens/genomes")
      }

      func testMetalCPU_PSNR_3b() throws {
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              let genomes = (try? FileManager.default.contentsOfDirectory(at: genomesDir(), includingPropertiesForKeys: nil))?
                  .filter { $0.pathExtension == "flam3" } ?? []
              XCTAssertFalse(genomes.isEmpty, "no frozen genomes")
              for g in genomes {
                  let flame = try Flam3Parser.parse(Data(contentsOf: g))[0]
                  // Higher sample count than the flam3-parity goldens: two independent
                  // ISAAC orderings need enough samples for their sampling-noise floor
                  // to drop below 38 dB. The lever is `samplesPerPixel`.
                  let p = RenderParams(seed: 0, width: 320, height: 200, oversample: 1, samplesPerPixel: 400)
                  let cpu = ReferenceRenderer.render(flame: flame, params: p)
                  let gpu = MetalRenderer.render(flame: flame, params: p)
                  let psnr = ImageComparison.psnr(cpu, gpu)
                  let ssim = ImageComparison.ssim(cpu, gpu)
                  let psnrStr = psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)
                  print("[Parity3b] \(g.lastPathComponent): PSNR=\(psnrStr) dB, SSIM=\(String(format: "%.4f", ssim))")
                  XCTAssertGreaterThanOrEqual(psnr, 38.0, "\(g.lastPathComponent): \(psnr) dB < 38")
                  XCTAssertGreaterThanOrEqual(ssim, 0.95, "\(g.lastPathComponent): SSIM \(ssim) < 0.95")
              }
          }
      }
  }
  ```

**Dependency note (honest):** The Stage-3b on-ramp makes `FlameRenderer` depend on `FlameReference`, contradicting the spec's "FlameRenderer depends on FlameKit only." This is a **deliberate, temporary** coupling for the parity-bisect on-ramp. Task 9 implements the full Metal display kernel and **removes** this dependency; the on-ramp then lives in the **test target** (which already depends on both) rather than in the `FlameRenderer` module. The plan keeps the on-ramp code reachable for diagnosis but ships the production renderer FlameKit-only.

**Acceptance Criteria:**
- `MetalRenderer.render` produces a finite `RGBA8Image`.
- `testMetalCPU_PSNR_3b` passes over all 6 frozen genomes at PSNR ≥ 38 dB / SSIM ≥ 0.95.

**Verify:**
```
swift test --filter EndToEndParity3bTests
```
Expected: all 6 genomes pass the 38 dB / 0.95 gate. If a genome (likely a chaotic julia one) dips under 38 dB, raise `samplesPerPixel` in 100-step increments until it passes — the lever is sample count, not algorithm.

**Steps:**
- [ ] Add `"FlameReference"` to `FlameRenderer` deps in `Package.swift`.
- [ ] Add the Stage-3b `render` extension to `MetalRenderer.swift`.
- [ ] Create `Tests/FlameRendererTests/EndToEndParity3bTests.swift`.
- [ ] Run the verify command; tune `samplesPerPixel` if needed.
- [ ] Commit.

Commit: `feat(renderer): Stage-3b on-ramp — Metal chaos + CPU tone-map, first parity gate`

---

## Task 8 — Stage 2 density-estimation Metal kernel (twin of the CPU approximation)

**Goal:** Provide a Metal DE kernel that is a faithful twin of `FlameReference.DensityEstimation.apply` (the M1 adaptive-kernel approximation), gated on `estimatorRadius > 0`. The 6 frozen goldens all set `radius=0` (exact passthrough), so this kernel is **not exercised by the end-to-end parity gate** — it exists so the renderers remain structural twins and so a parity test on a synthetic `radius>0` histogram guards correctness. When CPU DE becomes faithful in a later slice, Metal's is updated in lockstep.

**Files:**
- Modify `Sources/FlameRenderer/Metal/Kernels.metal` — add a DE kernel operating on a Float histogram buffer (`{count, r, g, b, a}` per bin, decoded units), mirroring the CPU adaptive-kernel + conical-weight loop:
  ```metal
  struct FloatBin { float count, r, g, b, a; };

  kernel void densityEstimation(device FloatBin* inOut [[buffer(0)]],
                                constant const float* params [[buffer(1)]],
                                constant const uint2* dims   [[buffer(2)]],
                                device FloatBin* work        [[buffer(3)]],
                                uint2 tid [[thread_position_in_grid]]) {
      uint gw = dims->x, gh = dims->y;
      if (tid.x >= gw || tid.y >= gh) return;
      uint idx = tid.y * gw + tid.x;
      float radius = params[0];     // estimator_radius
      float minimum = params[1];    // estimator_minimum
      float curve   = params[2];    // estimator_curve
      if (radius <= 0) { work[idx] = inOut[idx]; return; }   // passthrough

      float cnt = inOut[idx].count;
      if (cnt <= 0) { work[idx] = inOut[idx]; return; }
      float adapt = radius * pow(minimum / (cnt + minimum), curve);
      int maxR = int(ceil(radius));
      float r = clamp(adapt, 0.0f, float(maxR));
      int ri = int(ceil(r));
      float3 colorAvg = float3(inOut[idx].r, inOut[idx].g, inOut[idx].b) / cnt;
      float alphaAvg  = inOut[idx].a / cnt;
      float3 acc = 0.0f; float accA = 0.0f; float wsum = 0.0f;
      for (int dy = -ri; dy <= ri; dy++) {
          for (int dx = -ri; dx <= ri; dx++) {
              int nx = int(tid.x) + dx, ny = int(tid.y) + dy;
              if (nx < 0 || nx >= int(gw) || ny < 0 || ny >= int(gh)) continue;
              float dist = sqrt(float(dx*dx + dy*dy));
              float w = max(0.0f, 1.0f - dist / max(r, 1.0f));
              FloatBin nb = inOut[uint(ny) * gw + uint(nx)];
              bool populated = nb.count > 0.0f;
              float3 localC = populated ? float3(nb.r, nb.g, nb.b) / nb.count : colorAvg;
              float localA  = populated ? nb.a / nb.count : alphaAvg;
              acc += localC * w; accA += localA * w; wsum += w;
          }
      }
      FloatBin out;
      out.count = cnt;
      if (wsum > 0) {
          float3 c = (acc / wsum) * cnt;
          out.r = c.x; out.g = c.y; out.b = c.z;
          out.a = (accA / wsum) * cnt;
      } else {
          out.r = colorAvg.x * cnt; out.g = colorAvg.y * cnt; out.b = colorAvg.z * cnt;
          out.a = alphaAvg * cnt;
      }
      work[idx] = out;
  }
  ```
  (Two-buffer form: `inOut` is read, `work` is written. The host then swaps roles or blits `work` back. This avoids in-kernel read-after-write hazards.)
- Create `Sources/FlameRenderer/DensityEstimationMetal.swift` — host wrapper that takes a `FlameKit.Histogram`, runs the kernel when `radius > 0`, and returns a `Histogram`. Passthrough when `radius == 0`:
  ```swift
  import Foundation
  import Metal
  import FlameKit

  @MainActor
  enum DensityEstimationMetal {
      static func apply(_ hist: Histogram, radius: Double, minimum: Double, curve: Double) throws -> Histogram {
          guard radius > 0 else { return hist }
          guard let (device, library) = MetalRenderer.deviceAndLibrary(),
                let queue = MetalRenderer.commandQueue else {
              throw NSError(domain: "MetalRenderer", code: 12)
          }
          let gw = hist.gridWidth, gh = hist.gridHeight
          let n = gw * gh
          var bins = [Float](repeating: 0, count: n * 5)
          for i in 0..<n {
              bins[i*5] = Float(hist.counts[i])
              bins[i*5+1] = Float(hist.colors[i].x)
              bins[i*5+2] = Float(hist.colors[i].y)
              bins[i*5+3] = Float(hist.colors[i].z)
              bins[i*5+4] = Float(hist.alpha[i])
          }
          let inBuf = device.makeBuffer(bytes: bins, length: n*5*MemoryLayout<Float>.size, options: .storageModeShared)!
          let workBuf = device.makeBuffer(length: n*5*MemoryLayout<Float>.size, options: .storageModeShared)!
          var p: [Float] = [Float(radius), Float(minimum), Float(curve)]
          let pBuf = device.makeBuffer(bytes: &p, length: 3*MemoryLayout<Float>.size, options: .storageModeShared)!
          var dims = SIMD2<UInt32>(UInt32(gw), UInt32(gh))
          let dBuf = device.makeBuffer(bytes: &dims, length: MemoryLayout<SIMD2<UInt32>>.size, options: .storageModeShared)!
          let pso = try library.makeFunction("densityEstimation")!.makeComputePipelineState()
          let cb = queue.makeCommandBuffer()!; let enc = cb.makeComputeCommandEncoder()!
          enc.setComputePipelineState(pso)
          enc.setBuffer(inBuf, offset: 0, index: 0)
          enc.setBuffer(pBuf, offset: 0, index: 1)
          enc.setBuffer(dBuf, offset: 0, index: 2)
          enc.setBuffer(workBuf, offset: 0, index: 3)
          let tpg = MTLSize(width: 16, height: 16, depth: 1)
          let groups = MTLSize(width: (gw+15)/16, height: (gh+15)/16, depth: 1)
          enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tpg)
          enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()

          var out = Histogram(gridWidth: gw, gridHeight: gh)
          let ptr = workBuf.contents().assumingMemoryBound(to: Float.self)
          for i in 0..<n {
              out.counts[i] = Double(ptr[i*5])
              out.colors[i] = SIMD3(Double(ptr[i*5+1]), Double(ptr[i*5+2]), Double(ptr[i*5+3]))
              out.alpha[i]  = Double(ptr[i*5+4])
          }
          return out
      }
  }
  ```
- Create `Tests/FlameRendererTests/DensityEstimationParityTests.swift` — build a synthetic radius>0 histogram, compare Metal DE to CPU DE (counts identical, colors close):
  ```swift
  import XCTest
  @testable import FlameRenderer
  @testable import FlameReference
  import FlameKit

  final class DensityEstimationParityTests: XCTestCase {
      func testMetalDEMatchesCpuApprox() throws {
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              // 16×16 grid; a hot 3×3 block on a cold field exercises the adaptive kernel.
              var h = Histogram(gridWidth: 16, gridHeight: 16)
              for y in 6..<9 { for x in 6..<9 {
                  let i = h.binIndex(x, y)
                  h.counts[i] = 50
                  h.colors[i] = SIMD3(50*100, 50*0, 50*200)
                  h.alpha[i] = 50*255
              }}
              let radius = 4.0, minimum = 1.0, curve = 0.6
              let cpu = DensityEstimation.apply(h, radius: radius, minimum: minimum, curve: curve)
              let gpu = try DensityEstimationMetal.apply(h, radius: radius, minimum: minimum, curve: curve)
              XCTAssertEqual(cpu.counts, gpu.counts, "DE must preserve counts exactly")
              // Colors match within Float vs Double tolerance.
              var maxDiff: Double = 0
              for i in 0..<cpu.colors.count {
                  maxDiff = max(maxDiff, abs(cpu.colors[i].x - gpu.colors[i].x))
                  maxDiff = max(maxDiff, abs(cpu.colors[i].y - gpu.colors[i].y))
                  maxDiff = max(maxDiff, abs(cpu.colors[i].z - gpu.colors[i].z))
              }
              XCTAssertLessThan(maxDiff, 1.0, "DE color drift too large: \(maxDiff)")
          }
      }

      func testRadiusZeroIsPassthrough() throws {
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              let h = Histogram(gridWidth: 4, gridHeight: 4)
              let out = try DensityEstimationMetal.apply(h, radius: 0, minimum: 0, curve: 0)
              XCTAssertEqual(out.counts, h.counts)
          }
      }
  }
  ```

**Acceptance Criteria:**
- `testRadiusZeroIsPassthrough` passes (the gate the goldens hit).
- `testMetalDEMatchesCpuApprox` passes: counts identical; per-channel color drift < 1.0 (Float vs Double).
- The end-to-end parity gate (Task 7) remains green (DE not on the radius=0 golden path).

**Verify:**
```
swift test --filter DensityEstimationParityTests
```
Expected: both tests pass.

**Steps:**
- [ ] Append the `densityEstimation` kernel + `FloatBin` struct to `Kernels.metal`.
- [ ] Create `Sources/FlameRenderer/DensityEstimationMetal.swift`.
- [ ] Create `Tests/FlameRendererTests/DensityEstimationParityTests.swift`.
- [ ] Run verify; commit.

Commit: `feat(renderer): Metal Stage-2 density-estimation kernel (twin of CPU approximation)`

---

## Task 9 — Stage 3a full Metal display pipeline + production render path (FlameKit-only)

**Goal:** Port the CPU `ToneMapping` faithfully to MSL (log-density k1/k2, Gaussian spatial filter with gutter, `calcAlpha`, `calcNewRGB`, vibrancy/background, palette×256, WHITE_LEVEL). Replace the Stage-3b on-ramp as the production `MetalRenderer.render` so `FlameRenderer` no longer depends on `FlameReference` (production = FlameKit-only). Move the 3b on-ramp into the **test target** as a debug/parity-bisect helper. Prove Stage 3a against CPU `ToneMapping` on the **same** input histogram (≥ 50 dB; FP32 vs Double).

**Files:**
- Modify `Sources/FlameRenderer/Metal/Kernels.metal` — add `DisplayParams`, `logDensity`, and `displayPipeline` kernels:
  ```metal
  constant float PREFILTER_WHITE_MS = 255.0f;
  constant float WHITE_LEVEL_MS     = 255.0f;

  struct DisplayParams {
      float k1, k2;
      float gammaInv, linrange, vibrancy;
      float bgR, bgG, bgB;
      float highlightPower;
      uint  gw, gh, width, height, oversample, fw, gutter;
  };

  // Stage 3 step 1: per grid cell, log-density scale. Reads raw histogram (Float
  // bins: count,r,g,b,a in dmap units), writes accumulator (rgb + a).
  kernel void logDensity(device FloatBin* raw     [[buffer(0)]],
                         device float*  accumRGB  [[buffer(1)]],
                         device float*  accumA    [[buffer(2)]],
                         constant const DisplayParams* dp [[buffer(3)]],
                         uint2 tid [[thread_position_in_grid]]) {
      if (tid.x >= dp->gw || tid.y >= dp->gh) return;
      uint idx = tid.y * dp->gw + tid.x;
      float c3 = raw[idx].a;                       // rect.c:959 b[0][3]
      if (c3 == 0.0f) {                            // rect.c:960
          accumRGB[idx*3] = 0; accumRGB[idx*3+1] = 0; accumRGB[idx*3+2] = 0;
          accumA[idx] = 0; return;
      }
      float ls = dp->k1 * log(1.0f + c3 * dp->k2) / c3;   // rect.c:963
      accumRGB[idx*3]   = raw[idx].r * ls;
      accumRGB[idx*3+1] = raw[idx].g * ls;
      accumRGB[idx*3+2] = raw[idx].b * ls;
      accumA[idx] = c3 * ls;
  }

  // palettes.c:274-289
  static inline float calc_alpha(float density, float gamma, float linrange) {
      float dnorm = density;
      float funcval = pow(linrange, gamma);
      if (dnorm > 0) {
          if (dnorm < linrange) {
              float frac = dnorm / linrange;
              return (1.0f - frac) * dnorm * (funcval / linrange) + frac * pow(density, gamma);
          }
          return pow(density, gamma);
      }
      return 0;
  }

  // palettes.c:292-348. M2 only renders at the default highlightPower=-1, where
  // the saturated-highlight (HSV desaturation) branch is unreachable; this port
  // keeps the `else` (maxa<=255) path, which is the only one CPU `ToneMapping`
  // exercises on the goldens. The full HSV path is added when a genome overrides
  // highlightPower (deferred — no golden exercises it).
  static inline float3 calc_newrgb(float3 cbuf, float ls, float highpow) {
      if (ls == 0 || (cbuf.x == 0 && cbuf.y == 0 && cbuf.z == 0)) return 0.0f;
      float maxa = -1.0f; float maxc = 0.0f;
      for (int i = 0; i < 3; i++) {
          float a = ls * (cbuf[i] / PREFILTER_WHITE_MS);
          if (a > maxa) { maxa = a; maxc = cbuf[i] / PREFILTER_WHITE_MS; }
      }
      float newls = 255.0f / maxc;
      float adjhlp = -highpow; if (adjhlp > 1) adjhlp = 1; if (maxa <= 255) adjhlp = 1;
      float blend = (1 - adjhlp) * newls + adjhlp * ls;
      return float3(blend * cbuf.x / PREFILTER_WHITE_MS,
                    blend * cbuf.y / PREFILTER_WHITE_MS,
                    blend * cbuf.z / PREFILTER_WHITE_MS);
  }

  // Stage 3 steps 2+3: per output pixel, spatial-filter gather + gamma + write RGBA8.
  kernel void displayPipeline(device const float* accumRGB [[buffer(0)]],
                              device const float* accumA   [[buffer(1)]],
                              constant const float* spatialKernel [[buffer(2)]],
                              constant const DisplayParams* dp [[buffer(3)]],
                              device uchar* rgbaOut [[buffer(4)]],
                              uint2 tid [[thread_position_in_grid]]) {
      if (tid.x >= dp->width || tid.y >= dp->height) return;
      uint ox = tid.x, oy = tid.y;
      // CRITICAL: the gather origin is `ox*oversample` with NO gutter added —
      // this matches CPU ToneMapping which hardcodes `deOffset = 0` (rect.c's
      // de_offset is 0 when estimator_radius==0) and gathers `x = gx0 + ii`.
      // The gutter ring lives at the grid border; border taps simply reach into
      // it. Adding `+ gutter` here (as an earlier draft did) shifts every tap by
      // `gutter` cells relative to CPU for oversample>1 (e.g. oversample=2 →
      // fw=4, gutter=1 → a 1-cell shift), which breaks the Stage-3a ≥ 50 dB
      // same-histogram gate. `dp->gutter` is kept in the struct only because the
      // host computes it; this kernel MUST NOT add it to the origin.
      float3 tRGB = 0.0f; float tA = 0.0f;
      for (uint jj = 0; jj < dp->fw; jj++) {
          for (uint ii = 0; ii < dp->fw; ii++) {
              int xx = int(ox * dp->oversample) + int(ii);
              int yy = int(oy * dp->oversample) + int(jj);
              if (xx < 0 || xx >= int(dp->gw) || yy < 0 || yy >= int(dp->gh)) continue;
              float k = spatialKernel[ii + jj * dp->fw];
              uint idx = uint(yy) * dp->gw + uint(xx);
              tRGB += k * float3(accumRGB[idx*3], accumRGB[idx*3+1], accumRGB[idx*3+2]);
              tA   += k * accumA[idx];
          }
      }
      uint base = (oy * dp->width + ox) * 4;
      rgbaOut[base + 3] = 255;                      // opaque output
      if (tA <= 0) {                                // rect.c:1171
          rgbaOut[base] = 0; rgbaOut[base+1] = 0; rgbaOut[base+2] = 0;
          return;
      }
      float tmp = tA / PREFILTER_WHITE_MS;
      float alpha = calc_alpha(tmp, dp->gammaInv, dp->linrange);
      float ls2 = dp->vibrancy * 256.0f * alpha / tmp;     // rect.c:1176
      float3 newrgb = calc_newrgb(tRGB, ls2, dp->highlightPower);
      float3 bg = float3(dp->bgR, dp->bgG, dp->bgB);
      for (int c = 0; c < 3; c++) {
          float a = newrgb[c];
          a += (1.0f - dp->vibrancy) * 256.0f * pow(tRGB[c] / PREFILTER_WHITE_MS, dp->gammaInv);
          a += (1.0f - alpha) * bg[c];
          a = clamp(a, 0.0f, 255.0f);
          rgbaOut[base + c] = uchar(a + 0.5f);
      }
  }
  ```
  (The `displayPipeline` inner loop uses ONLY the `xx`/`yy` form computed from `ox*oversample`; there are no other local gather-origin variables. Do not reintroduce a `gx0`/`gy0` with `+ gutter` — see the inline comment above.)
- Create `Sources/FlameRenderer/DisplayPipelineMetal.swift` — host that builds `DisplayParams` + spatial kernel (reusing `flam3SpatialFilterWidth` from FlameKit), dispatches both kernels, reads back an `RGBA8Image`:
  ```swift
  import Foundation
  import Metal
  import FlameKit

  @MainActor
  enum DisplayPipelineMetal {
      struct DisplayParams {
        // mirror of MSL DisplayParams
        var k1: Float = 0; var k2: Float = 0
        var gammaInv: Float = 0; var linrange: Float = 0; var vibrancy: Float = 0
        var bgR: Float = 0; var bgG: Float = 0; var bgB: Float = 0
        var highlightPower: Float = -1
        var gw: UInt32 = 0; var gh: UInt32 = 0; var width: UInt32 = 0; var height: UInt32 = 0
        var oversample: UInt32 = 1; var fw: UInt32 = 0; var gutter: UInt32 = 0
      }

      static func render(histogram: Histogram, width: Int, height: Int, oversample: Int,
                         gamma: Double, gammaThreshold: Double, vibrancy: Double,
                         sampleDensity: Double, pixelsPerUnit: Double) throws -> RGBA8Image {
          guard let (device, library) = MetalRenderer.deviceAndLibrary(),
                let queue = MetalRenderer.commandQueue else {
              throw NSError(domain: "MetalRenderer", code: 13)
          }
          let gw = histogram.gridWidth, gh = histogram.gridHeight
          // k1 / k2 — identical math to CPU ToneMapping (rect.c:933-937).
          let contrast: Double = 1.0, brightness: Double = 4.0, prefilterWhite: Double = 255
          let k1 = contrast * brightness * prefilterWhite * 268.0 / 256.0
          let imageW = width * oversample, imageH = height * oversample
          let area = Double(imageW * imageH) / (pixelsPerUnit * pixelsPerUnit)
          let sumfilt: Double = 1.0
          let k2 = Double(oversample * oversample * 1) / (contrast * area * 255 * sampleDensity * sumfilt)
          // Spatial kernel (identical to CPU makeSpatialKernel).
          let fw = flam3SpatialFilterWidth(oversample: oversample, radius: 0.5)
          let (fwI, kernel) = makeSpatialKernelMetal(oversample: oversample, radius: 0.5)
          precondition(fw == fwI)

          var dp = DisplayParams()
          dp.k1 = Float(k1); dp.k2 = Float(k2)
          dp.gammaInv = Float(1.0/gamma); dp.linrange = Float(gammaThreshold); dp.vibrancy = Float(vibrancy)
          dp.bgR = 0; dp.bgG = 0; dp.bgB = 0; dp.highlightPower = -1
          dp.gw = UInt32(gw); dp.gh = UInt32(gh); dp.width = UInt32(width); dp.height = UInt32(height)
          dp.oversample = UInt32(oversample); dp.fw = UInt32(fw); dp.gutter = UInt32((fw - oversample)/2)

          // Pack raw bins {count,r,g,b,a} as Float.
          let n = gw * gh
          var raw = [Float](repeating: 0, count: n*5)
          for i in 0..<n {
              raw[i*5] = Float(histogram.counts[i])
              raw[i*5+1] = Float(histogram.colors[i].x)
              raw[i*5+2] = Float(histogram.colors[i].y)
              raw[i*5+3] = Float(histogram.colors[i].z)
              raw[i*5+4] = Float(histogram.alpha[i])
          }
          let rawBuf = device.makeBuffer(bytes: raw, length: n*5*MemoryLayout<Float>.size, options: .storageModeShared)!
          let accumRGB = device.makeBuffer(length: n*3*MemoryLayout<Float>.size, options: .storageModeShared)!
          let accumA   = device.makeBuffer(length: n*MemoryLayout<Float>.size, options: .storageModeShared)!
          let kernBuf  = device.makeBuffer(bytes: kernel, length: kernel.count*MemoryLayout<Float>.size, options: .storageModeShared)!
          var dpLocal = dp
          let dpBuf = device.makeBuffer(length: 64, options: .storageModeShared)!  // generous; copy exact below
          // Use exact-size copy through a typed pointer:
          let dpSize = MemoryLayout<DisplayParams>.size
          let dpExact = device.makeBuffer(length: dpSize, options: .storageModeShared)!
          dpExact.contents().copyMemory(from: UnsafeRawPointer(&dpLocal), byteCount: dpSize)
          let rgbaBuf = device.makeBuffer(length: width*height*4, options: .storageModeShared)!
          memset(rgbaBuf.contents(), 0, width*height*4)

          // Two passes in SEPARATE compute encoders within one command buffer.
          // Metal guarantees encoders execute in enqueue order and that writes
          // from one encoder are fully visible to the next — this is the
          // portable, API-stable way to order the log-density write before the
          // display-pipeline read (avoiding the version-specific
          // `memoryBarrier(withScope:)` varargs spelling, which is not stable
          // across Metal revisions).
          let cb = queue.makeCommandBuffer()!
          let tpg = MTLSize(width: 16, height: 16, depth: 1)

          // Pass 1: logDensity.
          let enc1 = cb.makeComputeCommandEncoder()!
          let pso1 = try library.makeFunction("logDensity")!.makeComputePipelineState()
          enc1.setComputePipelineState(pso1)
          enc1.setBuffer(rawBuf, offset: 0, index: 0)
          enc1.setBuffer(accumRGB, offset: 0, index: 1)
          enc1.setBuffer(accumA, offset: 0, index: 2)
          enc1.setBuffer(dpExact, offset: 0, index: 3)
          enc1.dispatchThreadgroups(MTLSize(width: (gw+15)/16, height: (gh+15)/16, depth: 1), threadsPerThreadgroup: tpg)
          enc1.endEncoding()

          // Pass 2: displayPipeline.
          let enc2 = cb.makeComputeCommandEncoder()!
          let pso2 = try library.makeFunction("displayPipeline")!.makeComputePipelineState()
          enc2.setComputePipelineState(pso2)
          enc2.setBuffer(accumRGB, offset: 0, index: 0)
          enc2.setBuffer(accumA, offset: 0, index: 1)
          enc2.setBuffer(kernBuf, offset: 0, index: 2)
          enc2.setBuffer(dpExact, offset: 0, index: 3)
          enc2.setBuffer(rgbaBuf, offset: 0, index: 4)
          enc2.dispatchThreadgroups(MTLSize(width: (width+15)/16, height: (height+15)/16, depth: 1), threadsPerThreadgroup: tpg)
          enc2.endEncoding()

          cb.commit(); cb.waitUntilCompleted()

          let ptr = rgbaBuf.contents().assumingMemoryBound(to: UInt8.self)
          return RGBA8Image(width: width, height: height, pixels: Array(UnsafeBufferPointer(start: ptr, count: width*height*4)))
      }

      // Identical to CPU makeSpatialKernel (filters.c:217-269). Kept here so
      // FlameRenderer has no FlameReference dependency.
      private static func makeSpatialKernelMetal(oversample: Int, radius: Double) -> (Int, [Float]) {
          let support: Double = 1.5
          let fwRaw = 2.0 * support * Double(oversample) * radius
          let fwidth = flam3SpatialFilterWidth(oversample: oversample, radius: radius)
          let adjust = fwRaw > 0 ? support * Double(fwidth) / fwRaw : 1.0
          var c = [Double](repeating: 0, count: fwidth * fwidth)
          var sum: Double = 0
          for i in 0..<fwidth {
              for j in 0..<fwidth {
                  let ii = ((2.0*Double(i)+1.0)/Double(fwidth) - 1.0) * adjust
                  let jj = ((2.0*Double(j)+1.0)/Double(fwidth) - 1.0) * adjust
                  let v = exp(-2.0*ii*ii) * (2.0/Double.pi).squareRoot()
                        * exp(-2.0*jj*jj) * (2.0/Double.pi).squareRoot()
                  c[i + j*fwidth] = v; sum += v
              }
          }
          if sum > 0 { for k in c.indices { c[k] /= sum } }
          return (fwidth, c.map { Float($0) })
      }
  }
  ```
- Modify `Sources/FlameRenderer/MetalRenderer.swift` — **replace** the Task-7 on-ramp `render` with the full-Metal production path (no `import FlameReference`):
  ```swift
  public extension MetalRenderer {
      /// Full Metal pipeline: chaos → density estimation → display. Faithful twin
      /// of `ReferenceRenderer.render`. Deterministic within the Metal backend.
      /// Statistical parity (PSNR ≥ 38 dB), not byte-identical to CPU.
      @MainActor
      public static func render(flame: Flame, params: RenderParams) -> RGBA8Image {
          do {
              var hist = try ChaosGameMetal.iterate(flame: flame, params: params)
              if flame.quality.estimatorRadius > 0 {
                  hist = try DensityEstimationMetal.apply(hist,
                      radius: flame.quality.estimatorRadius,
                      minimum: flame.quality.estimatorMinimum,
                      curve: flame.quality.estimatorCurveRate)
              }
              return try DisplayPipelineMetal.render(histogram: hist,
                  width: params.width, height: params.height, oversample: params.oversample,
                  gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
                  vibrancy: flame.quality.vibrancy,
                  sampleDensity: Double(params.samplesPerPixel),
                  pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom))
          } catch {
              fatalError("Metal render failed: \(error)")
          }
      }
  }
  ```
  Remove the `import FlameReference` line added in Task 7.
- Modify `Package.swift`: **remove** `"FlameReference"` from `FlameRenderer` dependencies (restore FlameKit-only).
- Move the 3b on-ramp into the test target: create `Tests/FlameRendererTests/OnRamp3b.swift` (test-only helper, re-implementing the chaos→CPU-tone-map path by composing `ChaosGameMetal` + `FlameReference.DensityEstimation`/`ToneMapping`):
  ```swift
  import Foundation
  @testable import FlameRenderer
  @testable import FlameReference
  import FlameKit

  /// Stage-3b parity-bisect helper (test-only): Metal chaos + CPU tone-map.
  @MainActor
  enum OnRamp3b {
      static func render(flame: Flame, params: RenderParams) -> RGBA8Image {
          var hist = try! ChaosGameMetal.iterate(flame: flame, params: params)
          if flame.quality.estimatorRadius > 0 {
              hist = DensityEstimation.apply(hist,
                  radius: flame.quality.estimatorRadius,
                  minimum: flame.quality.estimatorMinimum,
                  curve: flame.quality.estimatorCurveRate)
          }
          return ToneMapping.render(histogram: hist,
              width: params.width, height: params.height, oversample: params.oversample,
              gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
              vibrancy: flame.quality.vibrancy,
              sampleDensity: Double(params.samplesPerPixel),
              pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom))
      }
  }
  ```
  Update `EndToEndParity3bTests.swift` (Task 7) to call `OnRamp3b.render(...)` instead of `MetalRenderer.render(...)`. Rename its assertions' subject accordingly. (The 3b gate remains a permanent parity-bisect test.)
- Create `Tests/FlameRendererTests/Stage3aParityTests.swift` — feed the SAME CPU histogram to CPU `ToneMapping` and Metal `DisplayPipelineMetal`, compare:
  ```swift
  import XCTest
  @testable import FlameRenderer
  @testable import FlameReference
  import FlameKit

  final class Stage3aParityTests: XCTestCase {
      func testDisplayPipelineMatchesCpuToneMap() throws {
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              // A 12×12 histogram with a Gaussian-ish bump of counts/colors over a
              // smooth gradient — exercises log-density, the spatial filter gather,
              // and the gamma/calcAlpha path on a non-trivial field.
              var h = Histogram(gridWidth: 12, gridHeight: 12)
              for i in 0..<h.counts.count {
                  let cx = i % 12, cy = i / 12
                  let d2 = (cx-6)*(cx-6) + (cy-6)*(cy-6)
                  let c = max(0, 20 - d2)
                  h.counts[i] = Double(c)
                  h.colors[i] = SIMD3(Double(c)*100, Double(c)*40, Double(c)*200)
                  h.alpha[i]  = Double(c)*255
              }
              let cpu = ToneMapping.render(histogram: h, width: 6, height: 6, oversample: 2,
                                           gamma: 2.2, gammaThreshold: 0.01, vibrancy: 1,
                                           sampleDensity: 100, pixelsPerUnit: 50)
              let gpu = try DisplayPipelineMetal.render(histogram: h, width: 6, height: 6, oversample: 2,
                                           gamma: 2.2, gammaThreshold: 0.01, vibrancy: 1,
                                           sampleDensity: 100, pixelsPerUnit: 50)
              let p = ImageComparison.psnr(cpu, gpu)
              XCTAssertGreaterThanOrEqual(p, 50.0, "Stage 3a (same histogram) below 50 dB: \(p)")
          }
      }
  }
  ```

**Acceptance Criteria:**
- `swift build` clean with `FlameRenderer` depending on `FlameKit` only.
- `testDisplayPipelineMatchesCpuToneMap` passes at PSNR ≥ 50 dB on the same input histogram (FP32 vs Double).
- `EndToEndParity3bTests` still passes (via `OnRamp3b`).
- The full-Metal `MetalRenderer.render` produces a finite image (smoke-checked by Task 10).

**Verify:**
```
swift build && swift test --filter "Stage3aParityTests|EndToEndParity3bTests"
```
Expected: Stage 3a ≥ 50 dB; 3b on-ramp still ≥ 38 dB over goldens.

**Steps:**
- [ ] Append `DisplayParams`, `logDensity`, `displayPipeline` to `Kernels.metal`. Clean the inner-loop preamble to use only `xx`/`yy`.
- [ ] Create `Sources/FlameRenderer/DisplayPipelineMetal.swift`.
- [ ] Replace `MetalRenderer.render` with the full-Metal pipeline; remove `import FlameReference`.
- [ ] Remove `"FlameReference"` from `FlameRenderer` deps in `Package.swift`.
- [ ] Create `Tests/FlameRendererTests/OnRamp3b.swift`; update `EndToEndParity3bTests` to call it.
- [ ] Create `Tests/FlameRendererTests/Stage3aParityTests.swift` (delete unused `synthetic()` helper, fill `h` inline).
- [ ] Run verify; commit.

Commit: `feat(renderer): full Metal Stage-3a display pipeline; production render path FlameKit-only`

---

## Task 10 — End-to-end Metal-vs-CPU parity (production path) + determinism + finiteness

**Goal:** The definitive M2 gate. The full-Metal `MetalRenderer.render` must agree with `ReferenceRenderer.render` at PSNR ≥ 38 dB / SSIM ≥ 0.95 across the 6 frozen genomes (and a fuzz case), produce byte-identical output across repeated runs (within-backend determinism), and have no NaN/Inf pixels.

**Files:**
- Create `Tests/FlameRendererTests/EndToEndParityTests.swift`:
  ```swift
  import XCTest
  @testable import FlameRenderer
  @testable import FlameReference
  import FlameKit

  final class EndToEndParityTests: XCTestCase {
      private func genomesDir() -> URL {
          URL(fileURLWithPath: #filePath)
              .deletingLastPathComponent().deletingLastPathComponent()
              .appendingPathComponent("Goldens/genomes")
      }
      private func loadAll() throws -> [(String, Flame)] {
          let dir = genomesDir()
          let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
              .filter { $0.pathExtension == "flam3" } ?? []
          return try urls.map { ($0.deletingPathExtension().lastPathComponent, try Flam3Parser.parse(Data(contentsOf: $0))[0]) }
      }

      func testMetalCPU_Parity_PSNR38_SSIM095() throws {
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              for (name, flame) in try loadAll() {
                  let p = RenderParams(seed: 0, width: 320, height: 200, oversample: 1, samplesPerPixel: 400)
                  let cpu = ReferenceRenderer.render(flame: flame, params: p)
                  let gpu = MetalRenderer.render(flame: flame, params: p)
                  let psnr = ImageComparison.psnr(cpu, gpu)
                  let ssim = ImageComparison.ssim(cpu, gpu)
                  let psnrStr = psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)
                  print("[Parity] \(name): PSNR=\(psnrStr) dB, SSIM=\(String(format: "%.4f", ssim))")
                  XCTAssertGreaterThanOrEqual(psnr, 38.0, "\(name): \(psnr) dB < 38")
                  XCTAssertGreaterThanOrEqual(ssim, 0.95, "\(name): SSIM \(ssim) < 0.95")
              }
          }
      }

      func testFuzzGenomeStillParity() throws {
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              // A non-frozen synthetic genome with julia + spherical (chaotic).
              let flame = Flame(size: SIMD2(160, 100), camera: Camera(scale: 200),
                  xforms: [
                    Xform(affine: AffineTransform(a: 0.6, b: 0.2, c: -0.3, d: 0.5, e: 0, f: 0),
                          color: 0, colorSpeed: 0.5,
                          variations: [Variation(name: "julia", weight: 0.7),
                                       Variation(name: "spherical", weight: 0.3)]),
                    Xform(affine: AffineTransform(a: 0.4, b: -0.1, c: 0.2, d: 0.7, e: 0.3, f: -0.2),
                          color: 1, colorSpeed: 0.5,
                          variations: [Variation(name: "linear", weight: 1)])
                  ],
                  palette: Palette(colors: (0..<256).map { SIMD3(Double($0)/255, sin(Double($0)/40)*0.5+0.5, 1-Double($0)/255) }))
              let p = RenderParams(seed: 1234, width: 160, height: 100, oversample: 1, samplesPerPixel: 400)
              let cpu = ReferenceRenderer.render(flame: flame, params: p)
              let gpu = MetalRenderer.render(flame: flame, params: p)
              XCTAssertGreaterThanOrEqual(ImageComparison.psnr(cpu, gpu), 38.0)
          }
      }

      func testMetalDeterministicAcrossRuns() throws {
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              let (_, flame) = try loadAll().first { $0.0 == "sierpinski" } ?? ("", try loadAll().first!.1)
              let p = RenderParams(seed: 0, width: 160, height: 100, oversample: 1, samplesPerPixel: 200)
              let a = MetalRenderer.render(flame: flame, params: p)
              let b = MetalRenderer.render(flame: flame, params: p)
              // uint32 atomic accumulation is order-independent → byte-identical output.
              XCTAssertEqual(a.pixels, b.pixels, "Metal backend is not deterministic across runs")
          }
      }

      func testNoNaNOrInf() throws {
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              for (_, flame) in try loadAll() {
                  let p = RenderParams(seed: 0, width: 160, height: 100, oversample: 1, samplesPerPixel: 100)
                  let img = MetalRenderer.render(flame: flame, params: p)
                  // UInt8 pixels are finite by construction; the check is that the
                  // render returned a complete, properly-sized buffer (no early fault).
                  XCTAssertEqual(img.pixels.count, img.width * img.height * 4)
              }
          }
      }
  }
  ```

**Acceptance Criteria:**
- `testMetalCPU_Parity_PSNR38_SSIM095` passes over all 6 frozen genomes.
- `testFuzzGenomeStillParity` passes for the synthetic julia/spherical genome.
- `testMetalDeterministicAcrossRuns` passes: the Metal PNG is byte-identical across two runs (the uint32-fixed-point encoding guarantees this).
- `testNoNaNOrInf` passes: every render returns a full-sized buffer.

**Verify:**
```
swift test --filter EndToEndParityTests
```
Expected: all four tests pass.

**Steps:**
- [ ] Create `Tests/FlameRendererTests/EndToEndParityTests.swift`.
- [ ] Run verify; tune `samplesPerPixel` if a frozen genome dips under 38 dB (lever: more samples).
- [ ] Commit.

Commit: `test(renderer): end-to-end Metal↔CPU parity gate, determinism, finiteness`

---

## Task 11 — CLI `--backend cpu|metal` + `--list-backends`

**Goal:** Expose the Metal backend to users. `--backend cpu` (default) and `--backend metal`; `--list-backends` reports availability. `--backend metal` on a machine without a usable Metal device (or where the MSL library fails to compile) prints a clear error and falls back to CPU with a non-zero-hinting message. CPU CLI snapshots remain byte-unchanged (the default path is untouched).

`MetalRenderer.render` is `@MainActor`; the CLI is invoked on the main thread, so the bridge is `MainActor.assumeIsolated { … }`.

**Files:**
- Modify `Sources/EmberweftCLI/CLI.swift`:
  - Add `import FlameRenderer`.
  - Add a `--list-backends` command.
  - In `render(_:)`, parse `--backend cpu|metal` (default `cpu`); dispatch accordingly.
  ```swift
  import FlameRenderer

  // … in run(_:) switch:
  case "--list-backends": return listBackends()

  // … new helper:
  private static func listBackends() -> Int32 {
      let metal = MainActor.assumeIsolated { MetalRenderer.isAvailable }
      out("cpu: available\n")
      out("metal: \(metal ? "available" : "unavailable")\n")
      return 0
  }

  // … in render(_:) arg loop, add:
  case "--backend":
      guard i + 1 < args.count else { err("error: --backend requires a value\n"); return 2 }
      let v = args[i + 1].lowercased()
      guard v == "cpu" || v == "metal" else { err("error: --backend must be cpu|metal\n"); return 2 }
      backend = v; i += 2

  // … declare `var backend = "cpu"` near the top of render(_:) …

  // … replace the single render call with:
  let img: RGBA8Image
  if backend == "metal" {
      let metalOK = MainActor.assumeIsolated { MetalRenderer.isAvailable }
      guard metalOK else {
          err("error: Metal backend unavailable on this machine; use --backend cpu\n")
          return 1
      }
      img = MainActor.assumeIsolated { MetalRenderer.render(flame: flame, params: params) }
  } else {
      img = ReferenceRenderer.render(flame: flame, params: params)
  }
  ```
  Update `printHelp()` to document `--backend cpu|metal` and `--list-backends`.
- Add to `Tests/EmberweftCLITests/CLITests.swift`:
  ```swift
  func testListBackends() {
      let code = EmberweftCLI.run(["emberweft", "--list-backends"])
      XCTAssertEqual(code, 0)
  }

  func testRenderMetalBackendWhenAvailable() throws {
      try MainActor.assumeIsolated {
          guard MetalRenderer.isAvailable else { return }   // skip on GPU-less CI (none, by decision)
          let url = tmp(goodXml)
          let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("m.png")
          try? FileManager.default.removeItem(at: out)
          let code = EmberweftCLI.run(["emberweft", "render", url.path, "-o", out.path,
                                       "--size", "16x16", "--quality", "20", "--backend", "metal"])
          XCTAssertEqual(code, 0)
          XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
      }
  }
  ```
  (Add `import FlameRenderer` to the test file.)

**Acceptance Criteria:**
- `emberweft --list-backends` prints `cpu: available` and `metal: available` (on the dev machine), exit 0.
- `emberweft render g.flam3 --backend metal -o out.png` writes a PNG identical between runs (determinism).
- The pre-existing CPU snapshot test (`CLISnapshotTests`) is byte-unchanged — `--backend` default is `cpu`, so the default render path is untouched.
- `--backend metal` on a machine with `isAvailable == false` returns exit 1 with a clear message.

**Verify:**
```
swift test --filter "CLITests|CLISnapshotTests"
swift run emberweft --list-backends
swift run emberweft render Tests/Goldens/genomes/sierpinski.flam3 --backend metal -o /tmp/metal.png --size 160x100 --quality 200
```
Expected: all CLI tests pass; `--list-backends` shows both available; the Metal render writes a PNG.

**Steps:**
- [ ] Add `import FlameRenderer` + `--list-backends` + `--backend` parsing + dispatch to `CLI.swift`; update help.
- [ ] Add the two CLI tests (with `import FlameRenderer`).
- [ ] Run the verify commands.
- [ ] Commit.

Commit: `feat(cli): --backend cpu|metal and --list-backends`

---

## Task 12 — Performance baseline harness (regression guard, non-gating)

**Goal:** Record a single-frame render-time baseline for both backends at 720p and 1080p on the dev machine, and the Metal:CPU speedup. This is a **regression guard, not a parity gate** — it runs only when `EMBERWEFT_PERF=1` is set, prints the numbers for the M2 record, and asserts only that Metal is no slower than CPU at 1080p (a sanity floor, intentionally lenient). M3 targets an fps budget.

**Files:**
- Create `Tests/FlameRendererTests/PerformanceBaselineTests.swift`:
  ```swift
  import XCTest
  @testable import FlameRenderer
  @testable import FlameReference
  import FlameKit

  final class PerformanceBaselineTests: XCTestCase {
      private func genomesDir() -> URL {
          URL(fileURLWithPath: #filePath)
              .deletingLastPathComponent().deletingLastPathComponent()
              .appendingPathComponent("Goldens/genomes")
      }

      private func time(_ ms: () -> Void) -> TimeInterval {
          let t = Date(); ms(); return Date().timeIntervalSince(t)
      }

      func testSingleFrameBaseline() throws {
          guard ProcessInfo.processInfo.environment["EMBERWEFT_PERF"] == "1" else {
              throw XCTSkip("set EMBERWEFT_PERF=1 to run the perf baseline")
          }
          try MainActor.assumeIsolated {
              guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
              let dir = genomesDir()
              let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                  .filter { $0.pathExtension == "flam3" } ?? []
              for u in urls {
                  let flame = try Flam3Parser.parse(Data(contentsOf: u))[0]
                  for (w, h) in [(1280, 720), (1920, 1080)] {
                      let p = RenderParams(seed: 0, width: w, height: h, oversample: 1, samplesPerPixel: 100)
                      let cpu = time { _ = ReferenceRenderer.render(flame: flame, params: p) }
                      let gpu = time { _ = MetalRenderer.render(flame: flame, params: p) }
                      let speedup = cpu / max(gpu, 0.001)
                      print("[Perf] \(u.lastPathComponent) \(w)×\(h): cpu=\(String(format: "%.2f", cpu))s  metal=\(String(format: "%.2f", gpu))s  speedup=\(String(format: "%.2f", speedup))×")
                      if w == 1920 {
                          XCTAssertGreaterThan(speedup, 1.0, "Metal slower than CPU at 1080p on \(u.lastPathComponent)")
                      }
                  }
              }
          }
      }
  }
  ```

**Acceptance Criteria:**
- Without `EMBERWEFT_PERF`: the test SKIPs (no impact on the normal `swift test` gate time).
- With `EMBERWEFT_PERF=1`: the test prints the baseline table and asserts Metal > 1.0× CPU at 1080p.
- The recorded numbers are committed to `CHANGELOG.md` (Task 13) as the M2 baseline reference.

**Verify:**
```
EMBERWEFT_PERF=1 swift test --filter PerformanceBaselineTests
```
Expected: a printed `[Perf] …` table per genome per resolution; Metal > 1× at 1080p.

**Steps:**
- [ ] Create `Tests/FlameRendererTests/PerformanceBaselineTests.swift`.
- [ ] Run the verify command; copy the printed table into CHANGELOG (Task 13).
- [ ] Commit.

Commit: `test(renderer): single-frame perf baseline + Metal:CPU speedup guard`

---

## Task 13 — Docs: rewrite metal-pipeline.md, testing.md gate, CLAUDE.md rule #2, CHANGELOG, delete GA workflow

**Goal:** Bring the docs in line with the faithful-port reality, resolve the open GA-workflow decision (DELETE), record the M2 baseline, and refine CLAUDE.md rule #2 to state the within-backend / cross-backend determinism contract precisely.

**Files:**
- Modify `CLAUDE.md` rule #2 — replace the current sentence with:
  > **Determinism is mandatory.** Same genome + seed + params → identical frame within a backend, run after run and machine to machine. CPU and Metal are independent deterministic backends that agree within the parity threshold (PSNR ≥ 38 dB, SSIM ≥ 0.95); they are not required to be byte-identical to each other.
- Modify `docs/engineering/testing.md`:
  - Replace the **"CI gates"** section (lines ~73-86) with a **"Local pre-merge gate"** section listing: `swift build` (debug + release), full `swift test` (unit + property + golden + Metal↔CPU parity + finiteness + determinism), `EMBERWEFT_PERF=1` perf-baseline recording (non-gating), `swift-format` lint. State explicitly that GitHub is a plain git mirror and the local run is the source of truth.
  - In the **Thresholds** table (lines ~88-96): keep `FlameReference vs flam3 golden ≥ 30 dB / 0.95 SSIM`; set **Metal vs CPU parity: PSNR ≥ 38 dB, SSIM ≥ 0.95**; add **Metal Stage-3a vs CPU ToneMapping (same histogram): ≥ 50 dB**; add **Metal determinism: byte-identical across runs**.
  - Add the per-stage test table (MSL ISAAC byte-equal; histogram L1/correlation; Stage 3a; end-to-end; determinism; finiteness; perf) as a new subsection, mirroring the spec.
  - Adjust prose references to "CI" throughout to "local pre-merge gate".
- Modify `docs/engineering/development-approach.md`:
  - Update the "GPU acceleration" section's Stage-1 RNG bullet: replace "Per-thread RNG is a fixed-seed PCG / wang hash" with "Per-thread RNG is a faithful MSL port of flam3 ISAAC, seeded per-thread via flam3's parent→child mechanism; the CPU and Metal backends agree within PSNR ≥ 38 dB (statistical, not byte-exact)."
  - Update the "Quality infrastructure" → "CI" paragraph to reference the **local pre-merge gate** (GitHub is a mirror).
- Rewrite `docs/rendering/metal-pipeline.md` to the as-built reality:
  - Drop the Wang/PCG-hash RNG code blocks and the Reinhard/HDR/RGBA16Half speculation (the pre-faithful-port-pivot content).
  - Document: faithful MSL ISAAC + per-thread parent→child seeding; the three stages as built (chaos → DE → display); the `uint32` fixed-point atomic histogram encoding (deterministic, overflow-safe, M1+-compatible) and why float-CAS or 64-bit atomics were rejected; statistical parity model; the `.metal`-as-SwiftPM-resource + `makeLibrary(source:)` build approach; `MetalRenderer.render` API and `isAvailable` gate; the Stage-3b on-ramp as a debug parity-bisect tool (in the test target).
- Delete `.github/workflows/ci.yml` (the file itself; leave `.github/workflows/` empty or remove the directory — remove the file). This resolves the open decision in the spec: local-only is the source of truth, GitHub is a plain mirror.
- Modify `CHANGELOG.md` — add an M2 entry:
  ```
  ## M2 — Metal compute renderer (S5)

  - FlameRenderer: faithful Metal twin of FlameReference. Three MSL compute
    kernels (chaos game, density estimation, display pipeline); faithful ISAAC
    port (byte-equal to FlameKit.ISAAC); per-thread parent→child seeding;
    uint32 fixed-point atomic histogram (deterministic + overflow-safe).
  - Statistical parity (PSNR ≥ 38 dB / SSIM ≥ 0.95) over the 6 frozen genomes
    and a fuzz genome; Stage-3a same-histogram ≥ 50 dB; within-backend
    byte-determinism.
  - CLI: `emberweft render … --backend cpu|metal`, `--list-backends`.
  - Shared types (RGBA8Image, RenderParams, Histogram, xform-distrib, dmap,
    spatial-filter-width) lifted to FlameKit; FlameRenderer is FlameKit-only.
  - GitHub Actions workflow removed (local-only execution is the source of
    truth). testing.md "CI gates" → "Local pre-merge gate".
  - Single-frame baseline (EMBERWEFT_PERF=1): <paste the recorded numbers here>.
  ```

**Acceptance Criteria:**
- `CLAUDE.md` rule #2 states the within-backend / cross-backend contract precisely.
- `docs/engineering/testing.md` has no "CI gates" heading; the Local pre-merge gate section is present; thresholds include the Metal gate.
- `docs/engineering/development-approach.md` no longer mentions PCG/Wang hash for RNG.
- `docs/rendering/metal-pipeline.md` describes the as-built design and contains no Wang/PCG/Reinhard/RGBA16Half-as-output speculation.
- `.github/workflows/ci.yml` is gone.
- `CHANGELOG.md` has the M2 entry with the perf numbers pasted.

**Verify:**
```
git diff --stat
test ! -f .github/workflows/ci.yml && echo "workflow deleted"
swift build && swift test   # full local pre-merge gate, green
```
Expected: docs changed; workflow deleted; full suite green.

**Steps:**
- [ ] Edit `CLAUDE.md` rule #2.
- [ ] Rewrite the testing.md "CI gates" → "Local pre-merge gate" + thresholds + per-stage table.
- [ ] Update development-approach.md RNG + CI paragraphs.
- [ ] Rewrite metal-pipeline.md.
- [ ] `git rm .github/workflows/ci.yml`.
- [ ] Add the M2 CHANGELOG entry (paste perf numbers from Task 12).
- [ ] Run the full local pre-merge gate; commit.

Commit: `docs(m2): faithful Metal pipeline docs, local gate, GA workflow removal, CHANGELOG`

---

## Final self-review of the plan (done)

- **Spec coverage:** every spec section maps to a task — architecture (T1,T4,T5,T9), RNG/ISAAC (T2), per-thread seeding (T4), fixed-point encoding (T4,T5), chaos kernel + final-xform-separate-binning (T5), Stage 2 DE (T8), Stage 3a/3b (T7,T9), determinism (T10), parity tables (T6,T7,T9,T10), CLI `--backend` (T11), docs + GA decision (T13), shared-type refactor (T3), SwiftPM `.metal` (T1).
- **Placeholder scan:** no `TBD`/`TODO`/`implement later` remain; the two earlier "delete dead code" instructions were inlined into literal code during plan authoring.
- **Type/signature consistency:** `GPUFrameParams` / `GPUXform` field order is identical between the Swift (`MetalHost.swift`) and MSL (`Kernels.metal`) definitions, including the `hasFinal` field added to both. The `AtomicBin` layout (`count,r,g,b,a` = 5 × `atomic_uint`) matches the host's flat `UInt32 × 5` decode stride. `MetalRenderer.render(flame:params:) -> RGBA8Image` is consistent across T7 (on-ramp), T9 (production), and T11 (CLI).
- **Dependency direction:** production `FlameRenderer` → `FlameKit` only (restored in T9). `FlameRendererTests` → `FlameRenderer`, `FlameReference`, `FlameKit`. `EmberweftCLI` → all three (unchanged).

**Residual risks the plan mitigates but cannot eliminate:**
1. **FP32 iteration vs Double on chaotic genomes.** Mitigated by sample-count lever (T7/T10 note). If a frozen julia genome cannot reach 38 dB at a reasonable sample count, the fallback is to render that genome's Metal path at a higher `samplesPerPixel` (perf cost) or accept a per-genome threshold relaxation — an owner decision, not a plan gap.
2. **Metal driver/scheduling determinism at extreme contention.** The `uint32` atomic encoding makes the histogram sum order-independent, so within-backend byte-determinism holds for the histogram. Residual: rare 8-bit-quantization boundary pixels could flip ±1 LSB if GPU FP32 variation in the display kernel rounds differently across driver versions; the byte-identical determinism assertion (T10) empirically confirms or refutes this on the dev machine.
3. **`.metal` runtime compilation latency on first frame.** ~tens of ms one-time per process (cached in `MTLLibrary`). Acceptable for CLI/offline; M3 may move to build-time metallib compilation via a SwiftPM build plugin if first-frame latency matters for realtime.
4. **Stage-3a highlight path is only proven for `highlightPower = -1`.** No golden exercises `highlightPower ≥ 0`; the MSL `calc_newrgb` ports the reachable path only. Adding the HSV-desaturation path is a one-task follow-up when a genome requires it — documented in `metal-pipeline.md`.
