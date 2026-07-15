# Goldens — frozen genome set & flam3 reference PNGs

This directory holds Emberweft's **frozen `.flam3` genome set** and the
**committed reference PNGs** produced from them by the real `flam3-render`
oracle. Together they let CI assert render parity without ever installing
`flam3`.

## Layout

```
Tests/Goldens/
  genomes/        # frozen .flam3 genomes (input, versioned, hand-curated)
  reference/      # committed reference PNGs (output of flam3-render)
  README.md       # this file
```

Regeneration is driven by [`Tools/regen_goldens.sh`](../../Tools/regen_goldens.sh),
invoked via `make regen-goldens`.

## Frozen genome set

| File                | Covers                                         |
|---------------------|------------------------------------------------|
| `sierpinski.flam3`  | pure-linear, 3 linear xforms, 3-color palette  |
| `swirl_field.flam3` | `linear` + `swirl`                              |
| `julia_bubbles.flam3` | `julia` + `spherical`                         |
| `heart_disc.flam3`  | `heart` + `disc`                                |
| `final_warp.flam3`  | linear xforms + a `<finalxform>` (`julia`)      |
| `rich.flam3`        | 5 xforms, ≥6 distinct M1 variations             |

Every genome:

- Bakes `size="320 200" quality="100"` and `estimator_radius="0"` — there are
  no `flam3-render` environment variables for width/height/quality, so these
  values must be in the genome itself.
- Uses **only** variation names in `Variations.knownNames` (M1 set).
- Declares variation weights as **xform attributes**
  (e.g. `<xform linear="1" swirl="0.4"/>`) — the *only* form `flam3-render`
  reads. The `<var name weight>` child form is ignored by flam3 and would
  render blank.
- Uses a flam3-native hex-block `<palette>` (see "Palette form" below).

`Tests/FlameKitTests/GoldenGenomeTests.swift` asserts all of the above on
every commit, so the set cannot silently drift.

## Palette form — flam3 native hex-block

The genomes use **flam3's native hex-block palette form**:

```xml
<palette count="256" format="RGB">
FF1E1E
...
(256 lines, one 6-hex-digit RRGGBB color per line)
...
2850FF
</palette>
```

This is the form `flam3-genome`/`flam3-render` themselves emit, and the only
palette child form `flam3-render`'s parser accepts: it requires attributes
(`count` + `format`) on the `<palette>` element and reads the hex text content
via `flam3_parse_hexformat_colors` (see `parser.c` in scottdraves/flam3).

The Apophysis `<color index="i" rgb="RRGGBB"/>` child form is **rejected** by
`flam3-render` with `Error: No attributes for palette element.` — that form is
only for Emberweft's own parser and is therefore unsuitable for goldens.

`FlameKit.Flam3Parser` accepts **both** forms (`applyHexBlock` for the
hex-block, `<color>` children for Apophysis), so the hex-block genomes parse
cleanly in Emberweft too (asserted by `GoldenGenomeTests`).

## Regenerating the reference PNGs

Re-goldening is a **reviewed commit**: regen, eyeball the diff, and commit the
new PNGs with the genome/script changes. Reference PNGs are committed precisely
so CI never needs `flam3`.

One-time: build the dev-only oracle (outside the repo):

```sh
make bootstrap-oracle      # builds GPL flam3 into $HOME/flam3-oracle (dev-only)
```

Then regenerate:

```sh
PATH="$HOME/flam3-oracle/bin:$PATH" make regen-goldens
```

`make regen-goldens` runs `Tools/regen_goldens.sh`, which for each genome
invokes:

```sh
env format=png transparency=0 \
    seed=42 isaac_seed=emberweftgoldens nthreads=1 \
    in="Tests/Goldens/genomes/<name>.flam3" \
    out="Tests/Goldens/reference/<name>.png" flam3-render
```

`flam3-render` takes **all** parameters as environment variables (there are no
`--` flags, and no width/height/quality env var — those come from the genome).

## Reproducibility — pinned seeds, nthreads=1 & metadata normalization

`flam3-render` is **non-deterministic by default** because it has THREE
machine/time-dependent inputs:

| Input              | env var      | default              | used for                  |
|--------------------|--------------|----------------------|---------------------------|
| libc `srandom`     | `seed`       | `time(0)+getpid()`   | misc randomness           |
| ISAAC chaos-game   | `isaac_seed` | `time(0)` (string)   | the iteration loop        |
| thread count       | `nthreads`   | physical CPU count   | sample-batch parallelism  |

The harness **pins all three**. `seed` and `isaac_seed` make a render
byte-reproducible across runs; **`nthreads=1` is critical for parity** —
flam3's multi-threading splits the sample budget across N threads each seeded
with its OWN child ISAAC (rect.c:858-865), producing an N-way blend. Emberweft's
CPU reference is single-threaded (one ISAAC stream) for provable determinism,
so it can only match a single-threaded flam3 golden. Pinning `nthreads=1` also
makes the goldens machine-independent (independent of host CPU count). Measured:
flam3(`nthreads=1`) vs Emberweft = byte-identical per-bin counts; a multi-thread
golden vs Emberweft collapses to ~15-30 dB.

The defaults are constants, but each can be overridden from the environment to
intentionally re-seed/retread:

```
FLAM3_SEED=42
FLAM3_ISAAC_SEED=emberweftgoldens
FLAM3_NTHREADS=1
```

flam3 also embeds a `flam3_time` PNG `tEXt` chunk recording the render's
**elapsed seconds** (e.g. `"0"` vs `"1"`) — pixel-independent, but it breaks
raw-file `cmp` under varying machine load. The harness strips just that one
metadata chunk post-render (stdlib Python), so committed PNGs are
byte-identical regardless of host speed. The pixel data (PNG `IDAT`) and all
other metadata (genome, version, sample count) are left byte-intact.

> **Note:** Emberweft's CPU reference (`FlameReference`) ports flam3's ISAAC
> RNG + chaos-game consumption order byte-for-byte. With `nthreads=1` goldens,
> the two are **near-byte-exact** (PSNR 51-72 dB, SSIM ≈ 1.0 across all 6 frozen
> genomes) — not merely statistically correlated. Parity is asserted strict
> (≥30 dB / ≥0.95 SSIM) in `GoldenParityTests`.

## Parity status

All 6 frozen genomes achieve near-byte-exact parity with the flam3 goldens and
pass the strict gate (≥30 dB PSNR, ≥0.95 SSIM) in `GoldenParityTests`:

| Genome          | PSNR (dB) | SSIM  |
|-----------------|-----------|-------|
| `sierpinski`    | 63.4      | 1.000 |
| `heart_disc`    | 71.6      | 1.000 |
| `swirl_field`   | 61.6      | 1.000 |
| `rich`          | 53.8      | 1.000 |
| `julia_bubbles` | 51.6      | 1.000 |
| `final_warp`    | 67.2      | 1.000 |

This includes the `julia`-containing genomes (`julia_bubbles`, `final_warp`,
`rich`), which require the faithful ISAAC + Double-precision + operation-order
port to match flam3's chaotic trajectory sample-for-sample.

## Licensing & attribution (important)

`flam3` (scottdraves/flam3) is **GPL** and is used here strictly as a
**dev-only external oracle**. It is:

- **Never linked** into Emberweft.
- **Never bundled, copied, or distributed** with Emberweft.
- **Never referenced from `Package.swift`** — no build dependency.
- Present in this repo **only** as:
  1. the invocation in `Tools/regen_goldens.sh`,
  2. this documentation, and
  3. the committed PNG **output** it produced (PNG bytes carry no GPL obligation).

Emberweft is **source-available under PolyForm Noncommercial 1.0.0** (not OSI
"open source") and remains independent of the GPL. See
[docs/license-and-attribution.md](../../docs/license-and-attribution.md).
