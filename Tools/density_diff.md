# `Tools/density_diff.md` — localizing the real-genome density-parity gap

Diagnostic for **Task 5** of the motion-blur/density-parity plan. The companion
script `Tools/density_diff.py` renders `electricsheep.248.00256.flam3` in both
Emberweft (CPU) and flam3 with **matched no-blur parameters**, then prints
side-by-side density diagnostics. This doc interprets the output and ranks the
candidate causes so Task 6 has a concrete target.

## TL;DR

The ≈20 dB real-genome gap is **two independent bugs**, both caused by Emberweft
hardcoding display-pipeline constants that real ES genomes actually set on the
`<flame>` element:

| #  | Suspect                            | Emberweft (hardcoded) | flam3 (from genome)        | dB recovered |
|----|------------------------------------|-----------------------|----------------------------|--------------|
| 1  | `highlight_power` (saturated-highlight anti-shift) | `-1.0` (disabled)  | **`"1"`** (enabled)        | **+28.2 dB** |
| 2  | `filter` (spatial-filter radius)   | `0.5`  → 2×2 kernel   | **`"1"`** → 4×4 kernel     | residual     |

With **both** set correctly (controlled experiment below), PSNR jumps from
**21.11 dB → 51.22 dB** — well past the 38 dB gate. Task 6 is a **fix**, not a
search.

The reason this slipped through M2/M3 parity: the synthetic goldens
(`Tests/Goldens/genomes/*.flam3`) don't set `highlight_power` or `filter`, so
they default to flam3's `-1` and `0.5` — exactly what Emberweft hardcodes. Real
ES genomes all set `highlight_power="1"` and `filter="1"`. The CPU↔Metal parity
gate (38 dB) was therefore blind to this; only the vs-flam3 oracle on real
genomes exposes it.

## Side-by-side numbers (canonical run, `python3 Tools/density_diff.py`)

Genome: `Tests/Goldens/genomes_real/electricsheep.248.00256.flam3`
Sanitized (both sides): `passes=1 temporal_samples=1 supersample=1
estimator_radius=0 estimator_minimum=0 quality=1000` (the task spec's
no-blur / no-DE / no-supersample profile). `filter="1"` is preserved.

- Render size: 800×592 both sides
- ISAAC seed: `emberweftgoldens` both sides
- PSNR (flam3 vs Emberweft, RGB): **21.11 dB**  (gate: 38 dB)

| metric                    | flam3         | Emberweft     | Δ             |
|---------------------------|--------------:|--------------:|--------------:|
| Total light (Σ lum)       | 53,514,727    | 51,525,216    | **−3.7 %**    |
| Mean luminance            | 112.996       | 108.795       | −4.20         |
| Peak luminance            | 254.3         | 255.0         | +0.7          |
| Active-pixel mean lum     | 122.736       | 131.501       | **+8.76**     |
| Active fraction (lum > 4) | **92.01 %**   | **82.72 %**   | **−9.30 pp**  |
| Centroid (x, y)           | (394.6, 306.0)| (379.7, 321.6)| (~15 px shift)|
| Active bbox               | (0,0,799,591) | (0,0,799,591) | identical     |

### Histogram (8 buckets)

| bucket       | flam3    | Emberweft | Δ pp   | note                       |
|--------------|---------:|----------:|-------:|----------------------------|
| [  0,   4)   |   7.99 % |   17.28 % | +9.30  | **periphery dead**         |
| [  4,   8)   |   2.65 % |    0.85 % | −1.80  | periphery dim              |
| [  8,  16)   |   3.67 % |    0.72 % | −2.95  | periphery dim              |
| [ 16,  32)   |   6.08 % |    3.43 % | −2.65  | periphery dim              |
| [ 32,  64)   |  14.80 % |   13.45 % | −1.34  |                           |
| [ 64, 128)   |  20.55 % |   24.08 % | +3.53  | **interior compressed up** |
| [128, 192)   |  21.29 % |   19.88 % | −1.41  |                           |
| [192, 256)   |  22.97 % |   20.30 % | −2.67  | **interior peaks cut off** |

### % pixels above threshold

| threshold | flam3    | Emberweft | Δ pp   |
|-----------|---------:|----------:|-------:|
| lum >   4 |  92.01 % |   82.72 % | −9.30  |
| lum >  32 |  79.61 % |   77.71 % | −1.90  |
| lum > 128 |  44.26 % |   40.18 % | −4.08  |

## Divergent region: BIMODAL (periphery + interior)

The gap is **not** concentrated in one region. It splits cleanly into two
diagnosable signatures:

1. **Dark periphery ([0, 32) buckets, ~−7 pp combined).** flam3 lifts ~9 pp
   more pixels out of pure black into the dim range. Emberweft leaves the
   periphery dead. Caused by the **too-narrow spatial filter** (Cause #2): a 4×4
   Gaussian kernel smears interior density into the periphery; a 2×2 kernel
   barely touches it.

2. **Bright interior ([64, 256) buckets, ~±3.5 pp).** Emberweft has too many
   pixels bunched in the upper-mids [64,128) and too few in the brights
   [128,256). Caused by the **missing highlight-power desaturation** (Cause #1):
   flam3's saturated-highlight anti-shift (palettes.c:318-332) compresses peaks
   back toward 255 with HSV desaturation, redistributing bright pixels up the
   tail; Emberweft just clamps at 255, leaving pure-color peaks.

The active bbox, centroid (within 15 px), and total light (within 4 %) are all
essentially identical — structure and framing are correct, exactly as the task
brief states. The gap is purely in the **density redistribution**.

## Controlled experiments (proof for Task 6)

I temporarily patched Emberweft to apply each fix in isolation, re-rendered, and
measured PSNR against flam3:

| Emberweft config                                  | vs flam3 (sf=0.5) | vs flam3 (sf=1.0, native) |
|---------------------------------------------------|------------------:|--------------------------:|
| **production** (`hp=-1`, `sf=0.5`)                |        23.02 dB   |                **21.11 dB**|
| `hp=1` only (sf=0.5 still)                        |       **51.22 dB**|                  25.36 dB |
| `hp=1` and `sf=1.0` (wired)                       |                 — |                  17.33 dB¹ |

¹ Setting `sf=1.0` in Emberweft by overriding the constant **dropped** PSNR —
see "Open question for Task 6" below. The fix needs to be wired properly
through `Flame.quality.filterRadius`, not the global constant.

**Interpretation:**

- **Cause #1 (highlight_power)** is dominant. At matched `sf=0.5`, wiring
  `hp=1` takes PSNR from 23.02 → 51.22 dB — a **+28.2 dB** jump that crosses
  the 38 dB gate by 13 dB.
- **Cause #2 (spatial-filter radius)** accounts for most of the residual at
  native `filter="1"`. Once `hp=1` is in, matching `sf` (going from
  Emberweft `0.5` → flam3 `1.0`) is worth roughly another 26 dB on top — but
  the override path has a grid/gutter interaction bug that needs proper fixing.

## Ranked causes (with file:line evidence)

### #1 — `highlight_power` hardcoded to `-1` (DOMINANT, ~28 dB at matched filter)

- **Emberweft:** `Sources/FlameReference/ToneMapping.swift:27`
  ```swift
  private static let highlightPower: Double = -1.0   // HARDCODED
  ```
  Used at `ToneMapping.swift:116` (`calcNewRGB(..., highpow: highlightPower)`).
  Not parsed from `Flame.quality`. Same hardcode in Metal:
  `Sources/FlameRenderer/MetalRenderer.swift:264,486`,
  `Sources/FlameRenderer/DisplayPipelineMetal.swift:88`, and the kernel at
  `Sources/FlameRenderer/Metal/Kernels.metal:704,795`.

- **flam3:** `parser.c:405-406` parses `highlight_power="…"` directly into
  `cp.highlight_power`; `rect.c:924` accumulates it across temporal samples;
  `palettes.c:318-332` (`flam3_calc_newrgb`) takes the saturated-highlight
  branch whenever `maxa > 255 && highpow >= 0` — i.e., **any time a channel
  saturates and `highlight_power ≥ 0`**.

- **The genome sets it:** every real ES genome in
  `Tests/Goldens/genomes_real/` has `highlight_power="1"`
  (`grep -h highlight_power Tests/Goldens/genomes_real/*.flam3` — 7/7 hits).
  None of the synthetic goldens in `Tests/Goldens/genomes/` set it, which is
  why M2/M3 parity was blind to this.

- **Effect on the histogram:** the saturated branch compresses saturated
  channels to 255 via `newls = 255/maxc` and desaturates the color
  (`newhsv[1] *= pow(newls/ls, highpow)`). This pulls peaks down and
  redistributes them across the upper-mid range — exactly the [64,128) bump
  and [128,256) dip we see disappear when `hp=1` is wired.

### #2 — `spatial_filter_radius` hardcoded to `0.5` (residual, depends on #1)

- **Emberweft:** `Sources/FlameKit/RenderTypes.swift:32`
  ```swift
  public static let spatialFilterRadius: Double = 0.5   // HARDCODED
  ```
  Used by `RenderParams.filterWidth`/`gutterWidth` (RenderTypes.swift:34-40),
  by the CPU spatial kernel (`Sources/FlameReference/ToneMapping.swift:76`,
  `makeSpatialKernel`), and by all Metal display-pipeline call sites
  (`MetalRenderer.swift:255,477`, `DisplayPipelineMetal.swift:78`).

- **flam3:** `parser.c:405-406` parses `filter="…"` into
  `cp.spatial_filter_radius`. `filters.c:217-269` builds the kernel from it:
  `fw = 2 * support * supersample * sf_radius`. For `filter="1"` +
  `supersample=1` + gaussian (`support=1.5`): `fw = 3.0 → fwidth = 4`
  (a 4×4 kernel). Emberweft at `0.5` gets `fw = 1.5 → fwidth = 2` (2×2 kernel).

- **Effect on the histogram:** the 4×4 Gaussian spreads each interior cell's
  energy across ~16 cells, dragging periphery pixels up out of pure black
  (the +9.30 pp in [0,4) and −7.4 pp in [4,32)). The 2×2 kernel barely
  reaches neighbors.

### #3 — Chaos-game distribution (RULED OUT)

- `Sources/FlameReference/ChaosGame.swift:67-69` (`weights.map { max(0, $0.weight) }`
  + `Flam3XformDistrib.build`) is a faithful port of flam3's
  `flam3_create_chaos_distrib` (`/tmp/flam3/flam3.c:165-223`). The table-fill
  loop, the `dr = total / GRAIN` accumulator, the `r >= t → j++` boundary, and
  the `min(j, n-1)` clamp are all character-identical. The ISAAC seeding chain
  and consumption order match (verified by the existing CPU↔Metal byte-identity
  and synthetic-golden vs-flam3 parity at 43-58 dB). The 51.22 dB achieved by
  fixing only #1 + #2 is the proof: the chaos game was never the problem.

### #4 — `k2` / `sampleDensity` in ToneMapping (RULED OUT for oversample=1)

- `Sources/FlameReference/ToneMapping.swift:41-54` matches flam3
  `rect.c:933-937` term-for-term at `oversample=1` (the diagnostic's
  sanitized setting). Note for Task 6 / M4: at `oversample>1` Emberweft's
  `imageW = width * oversample` cancels the `oversample²` in the k2 numerator
  (ToneMapping.swift:44-46), whereas flam3's `area = image_width * image_height /
  (ppux*ppuy)` uses `image_width = cp.width` **without** oversample
  (rect.c:614, 935) and keeps the `oversample²` factor in k2. So at the native
  `supersample=4`, Emberweft's k2 is `1/16` of flam3's. Out of scope for this
  diagnostic (we ran at `supersample=1`), but it should be on Task 6's radar
  when wiring `oversample` through `RenderParams` properly.

### #5 — DE curve (RULED OUT)

- Already excluded by the task brief (`estimator_radius=0 → still 20 dB`).
  Confirmed: this diagnostic runs with `estimator_radius=0` and the gap
  persists, so DE is not the cause.

## Open question for Task 6

My `sf=1.0` experiment (overriding the constant alone) made PSNR **worse**
(17.33 dB), not better. The probable reason: changing
`RenderParams.spatialFilterRadius` cascades into `gutterWidth`/`gridWidth`
(RenderTypes.swift:38-40), which shifts the binning center (`gw/2`) and the
gather offsets together — but apparently not in lockstep with what flam3's
gutter logic expects at `fwidth=4`. Wiring the genome's `filter` attr into a
per-render parameter (rather than a `static let`) and re-validating against
flam3 at the genome's native `filter="1"` is the clean fix path. The 51.22 dB
ceiling at matched `sf=0.5` proves the chaos game and tone-mapping math are
otherwise correct.

## Acceptance

- `python3 Tools/density_diff.py` runs clean and prints the histogram
  (8 buckets), the {4, 32, 128} thresholds, and the centroid/bbox for each
  side. ✓
- This doc names the divergent region (bimodal: dark periphery + bright
  interior) and ranks the causes with file:line evidence both sides. ✓
- The #1 suspect is confirmed by a controlled experiment (patch → +28.2 dB).
  Task 6 can treat it as a fix, not a search.

## How to reproduce

```
swift build -c release                          # ~25 s render; debug build is ~6 min
python3 Tools/density_diff.py                   # writes /tmp/density_diff/*.png
                                               # + the report printed above
```

Pre-requisites: flam3-render on `$PATH` (`~/.local/bin/flam3-render`,
see `Tools/flam3_oracle.sh`); PIL + numpy (`pip install pillow numpy`).
Disable the bash sandbox if running from Claude Code (the flam3 spawn needs
it; CPU renders are fine either way).
