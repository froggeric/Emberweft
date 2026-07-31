# Animation: loops, transitions, and motion blur

`emberweft animate` renders the Electric Sheep animation model — an endless alternation of **loops** (one sheep rotating) and **transitions** (two sheep morphing) — as a PNG sequence + `manifest.json`. Mux to video with `ffmpeg`. This is a faithful port of flam3's `sheep_loop` / `sheep_edge` / `temporal_samples`.

## Segment model

A timeline is a sequence of **segments**. Each segment emits `--frames N` PNGs. Segments alternate by id parity:

| segment id | kind        | genomes          | flam3 fn      |
|------------|-------------|------------------|---------------|
| even       | **loop**    | one sheep        | `sheep_loop`  |
| odd        | **transition** | two sheep (A→B) | `sheep_edge`  |

So `--segments 1` is a single loop; `--segments 3` is loop(A) → transition(A→B) → loop(B); `--segments 4` is loop(A) → transition(A→B) → loop(B) → transition(B→C); and so on. The next sheep for each transition is chosen by the `--selector`.

- **Loop (`sheep_loop`)** — pure affine rotation `R(θ)·M` of each animating, non-final xform's pre-affine 2×2, with `θ = t·2π·cycles` (`t ∈ [0,1]` over the segment). **Palette is static during a loop** (seamless because `R(360°)=R(0°)` within FP residual). One genome is enough.
- **Transition (`sheep_edge`)** — `SpecialSauce.align` (pad to equal xform counts) → establish refangles → rotate both endpoints by `t·360°` → interpolate A→B with `interpolation_type=log` + HSV-circular palette blend. Needs ≥2 genomes.

## Command reference

```
emberweft animate <genome.flam3> [<genome.flam3> …] [flags] --out <dir/>
```

| flag | default | meaning |
|------|---------|---------|
| `--segments N` | 3 | number of segments (alternating loop/transition). `1` = single-sheep loop; `>1` needs ≥2 genomes. |
| `--frames N` | 8 | frames per segment (one loop revolution spans N frames). |
| `--loop-cycles N` | 1 | full revolutions per loop segment (`N>1` spins faster; seamless for integer N). |
| `--backend cpu\|metal` | cpu | `metal` is ~12–18× faster; `cpu` is byte-deterministic. |
| `--size WxH` | 1920x1080 | output frame size. |
| `--quality Q` | 100 | samples per pixel (higher = less noise; real genomes look good at 500–2000). |
| `--temporal-samples N` | genome's `temporal_samples` (CPU) | motion-blur sub-passes. Capped at 64 on Metal. `1` = sharp (no blur). |
| `--seed S` | 42 | RNG seed (deterministic per backend). |
| `--selector sequential\|similarity` | sequential | how the next sheep is picked for transitions. `similarity` needs `--library <dir>`. |
| `--stagger`, `--library`, `--out`, `--frame N` | — | per-xform transition stagger, genome library dir, output dir, render only global frame `N` (re-render one frame after a change). |

## Examples

### Single-sheep loop (one genome)

```bash
swift run -c release emberweft animate sheep.flam3 \
  --segments 1 --frames 160 --loop-cycles 1 \
  --backend metal --size 1280x720 --quality 500 --temporal-samples 32 --out loop/
ffmpeg -framerate 30 -i loop/%06d.png -c:v libx264 -pix_fmt yuv420p -movflags +faststart loop.mp4
```

Produces a ~5.3 s (160 frames @ 30 fps) video of the sheep rotating one full turn, motion-blurred.

### Edge / transition (two genomes)

```bash
swift run -c release emberweft animate a.flam3 b.flam3 \
  --segments 3 --frames 160 --loop-cycles 1 --selector sequential \
  --backend metal --size 1280x720 --quality 500 --temporal-samples 32 --out edge/
ffmpeg -framerate 30 -i edge/%06d.png -c:v libx264 -pix_fmt yuv420p -movflags +faststart edge.mp4
```

Produces loop(A) → morph A→B → loop(B) — 480 frames, ~16 s.

### Sequence of many sheep (long-form video)

Pass N genomes with `--segments 2N−1`; loops and transitions alternate over all of them (the Electric Sheep model). `--selector sequential` walks them in the order given:

```bash
swift run -c release emberweft animate s1.flam3 s2.flam3 s3.flam3 s4.flam3 \
  --segments 7 --frames 160 --loop-cycles 1 --selector sequential \
  --backend metal --size 1280x720 --quality 1000 --temporal-samples 32 --out flock/
ffmpeg -framerate 30 -i flock/%06d.png -c:v libx264 -pix_fmt yuv420p -movflags +faststart flock.mp4
```

### Tips

- **Build with `-c release`** for renders (debug is ~14× slower).
- **Disable the bash sandbox** if invoking under one — `MTLCreateSystemDefaultDevice()` returns nil sandboxed, so `--backend metal` fails.
- **Quality vs time**: `--quality 500 --temporal-samples 32` at 1280×720 is a good preview/production balance on Metal. For final offline fidelity use `--backend cpu --quality 2000 --temporal-samples 1000` (slow; honors the genome's full temporal samples).
- **Determinism**: the same genomes + `--seed` + flags produce identical output run-to-run within a backend. CPU and Metal agree within the parity threshold (≥38 dB) but are not byte-identical to each other.
- **Seamless transitions**: keep `--temporal-samples ≥ 16` (motion blur is what makes the morph read as continuous). Since v0.1.10, one-sided variation "leaks" are clipped in `mergeVariations` so a loop and its following transition render the shared endpoint genome identically (no over-bright "elements appearing" jump at the boundary).
- **Patch one frame**: `--frame N` writes only `00000N.png` (skips the rest), so after a fix you can re-render just the affected frame(s), copy them over the old PNGs, and re-mux, instead of re-rendering the whole sequence.

## Motion blur

Motion blur is flam3's `temporal_samples`, ported faithfully: each frame runs `N` chaos sub-passes at sub-times across a ±`temporal_filter_width/2` window, with `color_scalar` (the temporal weight) baked into the dmap and `sumfilt` threaded into the log-density `k2`. It is **cost-neutral** (total samples unchanged) and **render-time** (not a video post-process). Box / gaussian / exp filters are supported (`TemporalFilter`).

The default `--temporal-samples` on CPU is the genome's own `temporal_samples` attribute (real ES genomes: 1000); on Metal it caps at 64 to bound dispatch overhead.
