# M4 Final Items — Durable Plan (survives context compaction)

**Status:** v0.3.0 is shipped (tagged, merged, pushed, released). These two items
are the final M4 polish. Execute them post-compaction.

**Repo:** /Volumes/ssd/github/emberweft · **Branch:** create `feat/m4-final` from `main`.
**Read CLAUDE.md first** (it has the M4 GUI gotchas, determinism rule #2, Swift 6 rules).

## Context
M4 shipped a native macOS GUI studio (NavigationSplitView sidebar, multi-select,
sentiment, collections, non-modal playback, off-main thumbnails). 112 EmberweftUITests
green. The M1–M3 engine (FlameKit/FlameReference/FlameRenderer/FlamePlayer) is
unchanged by M4 GUI work. Two items remain:

---

## Item 1: Configurable Preview Presets + FPS Display

**Why:** The user needs to see and adjust preview quality parameters (spp,
resolution, oversample) and measure the real-time impact (FPS) to tune for their
machine. Currently params are fixed in AppPreferences with no in-window visibility
or FPS feedback. Applies to BOTH single-genome preview AND collection-sequence
playback.

### Design

**PreviewPreset** (new, in `Sources/EmberweftUI/AppPreferences.swift`):
```swift
public enum PreviewPreset: String, Codable, CaseIterable, Sendable {
    case draft     // 480p (854x480), spp=2, oversample=1  — current default
    case balanced  // 720p (1280x720), spp=8, oversample=1
    case quality   // 1080p (1920x1080), spp=16, oversample=2
    case custom    // user-tunable (uses previewWidth/Height/SPP directly)
    var width: Int { ... }
    var height: Int { ... }
    var samplesPerPixel: Int { ... }
    var oversample: Int { ... }
}
```
Add `var previewPreset: PreviewPreset = .draft` to AppPreferences (backward-compat
via `decodeIfPresent` in `init(from:)` — old preferences.json without the field
loads as `.draft`, the current behavior).

`AppPreferences.previewParams()` respects the preset: when not `.custom`, derive
width/height/spp/oversample from the preset; when `.custom`, use the individual
`previewWidth`/`previewHeight`/`previewSamplesPerPixel` fields (as today).

**FPS measurement** in `Sources/EmberweftUI/PlaybackViewModel.swift`:
- Add `public private(set) var measuredFPS: Double = 0`.
- In the loop body (`startLoop`'s while loop), record `clock.now()` per frame;
  compute a rolling average of the last ~30 frame intervals → `measuredFPS =
  1.0 / avgInterval`. Reset to 0 when paused/stopped.
- The FPS is a **diagnostic metric** (non-deterministic by nature — wall-clock
  timing). This does NOT violate rule #2 (it's not render output). The preset→params
  mapping IS deterministic.
- **Inert-body note:** `measuredFPS` changes per frame, but it's in the transport bar
  (which already re-evaluates per frame via `position`). So adding it doesn't increase
  the per-frame re-evaluation scope.

Same for `Sources/EmberweftUI/SequencePlaybackViewModel.swift` (if it has a loop;
measure in its run loop).

**UI** — transport bar in `Sources/EmberweftGUI/PlaybackView.swift` AND
`Sources/EmberweftGUI/CollectionPlaybackView.swift`:
- Add an **FPS readout** (monospaced `"60.0 fps"`) near the existing frame/time
  readout. Bound to `vm.measuredFPS`.
- Add a **gear/preset button** (SF Symbol `slider.horizontal.3`) that opens a
  `.popover` with:
  - Preset `Picker` (Draft / Balanced / Quality / Custom).
  - When Custom: `Stepper`s for spp (1–64), width, height, oversample.
  - `Stepper` for target FPS (24/30/60/90/120).
  - A **"Reset to Default"** button → sets preset to `.draft` (the recallable default).
- Changing the preset/params: call `vm.load(flame:params:backend:targetFPS:...)`
  with the new params (re-loads the VM with updated params; for single-genome,
  re-derives from the same flame; for sequence, the SequencePlaybackViewModel
  restarts with new params). Apply immediately.

**Files to touch:**
- `Sources/EmberweftUI/AppPreferences.swift` — PreviewPreset + previewPreset field +
  previewParams() respects it.
- `Sources/EmberweftUI/PlaybackViewModel.swift` — measuredFPS + rolling average.
- `Sources/EmberweftUI/SequencePlaybackViewModel.swift` — measuredFPS (same pattern).
- `Sources/EmberweftGUI/PlaybackView.swift` — FPS readout + preset popover.
- `Sources/EmberweftGUI/CollectionPlaybackView.swift` — FPS readout + preset popover.
- `Tests/EmberweftUITests/AppPreferencesTests.swift` — preset round-trip + .custom
  fields + backward-compat (old prefs → .draft).

**Constraints:** rule #2 (preset mapping deterministic; FPS is diagnostic);
backward-compat; GUI has no test target (preset logic in EmberweftUI). FPS display
doesn't violate the inert-body guarantee (transport bar already re-evaluates via
position). Run `swift test --filter EmberweftUITests` green. Launch GUI for manual
FPS verification: `cd .build/arm64-apple-macosx/debug && ./emberweft-gui &`.

---

## Item 2: testFiniteDeterministicRenders / cell-variation fix

**Why:** The full `swift test` gate is red (pre-existing, confirmed on pristine
main). A `testFiniteDeterministicRenders` crash in the FlameKit `cell` variation
(`Int(Inf)` from `cell_size=0`). Root-caused (investigation report available);
faithful fix ready. Blocks honest "all tests green" claims.

### Root cause (confirmed)
`Sources/FlameKit/Variations.swift:1535-1537`, the `cell` variation:
```swift
let cs = resolve("cell", "cell_size", par)   // descriptor default = 0
let inv = 1.0 / cs                           // 1.0/0.0 = +Inf
var x = Int(floor(p.x * inv))                // Int(±Inf) → TRAP
```
`GenomeGen.make` (Tests/FlameReferenceTests/Genome+Gen.swift:27) selects parametric
variations without setting `cell_size`, so it resolves to its default 0. flam3's C
`(int)floor(tx*(1.0/0.0))` is UB but nontrapping (degenerates to linear output the
chaos game tolerates); Swift's `Int(Double)` traps.

### Fix (faithful)
Add a small `intTrunc(_:)` helper replicating C's nontrapping `(int)` cast:
```swift
/// Replicate C's `(int)` cast: NaN→0, ±Inf→±Int.max, in-range→truncate.
/// Bit-identical to `Int(d)` for finite in-range `d` (zero parity impact).
private func intTrunc(_ d: Double) -> Int {
    if d.isNaN { return 0 }
    if d >= Double(Int.max) { return Int.max }
    if d <= Double(Int.min) { return Int.min }
    return Int(d)
}
```
Swap `Int(floor(...))` → `intTrunc(floor(...))` at:
- `Variations.swift:1536-1537` (cell — **certain** trap site)
- `Variations.swift:1408` (rings2 — **latent** same-class)
- `Sources/FlameReference/ChaosGame.swift:237` (palette index — **latent**)

Leave `fan2` (1396) unchanged (provably in-range). Do NOT change the math; only the
Int conversion guard.

**Parity impact:** For all finite, in-range inputs (normal genomes with
`cell_size > 0`), `intTrunc(d) == Int(d)` → **zero parity impact**. For
`cell_size = 0`, the saturated sentinel × 0 = 0, reproducing flam3's exact degenerate
output `(w·p.x, -w·p.y)`.

**Files to touch:**
- `Sources/FlameKit/Variations.swift` — add `intTrunc` + apply at cell + rings2.
- `Sources/FlameReference/ChaosGame.swift` — apply at palette index.

**Verification:**
- `swift test --filter testFiniteDeterministicRenders` — must pass (no crash).
- `swift test --filter FlameReferenceTests` — no regression (the fix is a pure guard;
  normal inputs are unchanged).
- Commit: `fix(flamekit): intTrunc guard on Int(Double) in cell/rings2/ChaosGame
  (testFiniteDeterministicRenders crash)`.

---

## Ordered build sequence

1. **Item 2 (testFiniteDeterministicRenders fix)** — quick (5-line helper + 3
   call-site swaps), unblocks the full test gate, separate from GUI. Do first.
2. **Item 1 (preview presets + FPS)** — the GUI feature. Build test-first
   (AppPreferencesTests for preset), then FPS measurement, then UI popover + readout.
3. **Verify + commit each**, run `swift build` + `swift test --filter EmberweftUITests`
   green after each. For Item 2, also run `swift test --filter testFiniteDeterministicRenders`.
4. Launch the GUI (`cd .build/arm64-apple-macosx/debug && ./emberweft-gui &`) for
   manual FPS/preset verification.
5. Commit on `feat/m4-final`; merge to main; tag `v0.3.1`; push; release.

## Key references (read these before starting)
- `CLAUDE.md` — M4 GUI gotchas (activation, DnD, @Observable stores, GUI no test
  target, NSEvent.modifierFlags), determinism rule #2, @MainActor tests.
- `Sources/EmberweftUI/AppPreferences.swift` — the preferences model + previewParams().
- `Sources/EmberweftUI/PlaybackViewModel.swift` — the loop body (where FPS is measured).
- `Sources/EmberweftGUI/PlaybackView.swift` — the transport bar (where FPS + preset UI go).
- `Sources/FlameKit/Variations.swift:1535-1537` — the trap site (cell variation).
- `Tests/FlameReferenceTests/PropertyTests.swift` — testFiniteDeterministicRenders.
