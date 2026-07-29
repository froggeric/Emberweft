# CLAUDE.md — guidance for AI assistants working on Emberweft

Emberweft is a native macOS (Apple Silicon, Metal 4) re-implementation of Scott Draves' **fractal flame** algorithm — the basis of the *Electric Sheep* screensaver. It is a generative-video studio: realtime playback of morphing flame "sheep", long-form export, audio-reactive music videos, a macOS screensaver, and multi-resolution output up to 4K.

## Authoritative documents

Read these before making non-trivial changes. They override any generic assumption:

- **[docs/engineering/development-approach.md](docs/engineering/development-approach.md)** — *how* we build: Reference-then-Optimize methodology, S0–S12 build order, Metal-compute decision, CLI-first.
- **[docs/engineering/testing.md](docs/engineering/testing.md)** — test layers, oracles, local pre-merge gate, thresholds.
- **[docs/engineering/roadmap.md](docs/engineering/roadmap.md)** — milestones M0–M8 and the milestone↔slice map.
- **[docs/architecture.md](docs/architecture.md)** — modules and data flow.
- **[docs/license-and-attribution.md](docs/license-and-attribution.md)** — licensing & attribution.

## Core engineering rules (do not violate)

1. **Reference-then-Optimize.** `FlameReference` (CPU, Swift) is built and proven first, then `FlameRenderer` (Metal) is validated against it. Do not build Metal behavior that isn't matched by the CPU oracle.
2. **Determinism is mandatory.** Same genome + seed + params → identical frame within a backend, run after run and machine to machine. CPU and Metal are independent deterministic backends that agree within the parity threshold (PSNR ≥ 38 dB, SSIM ≥ 0.95); they are not required to be byte-identical to each other.
3. **Test-first.** Write the failing test (golden / parity / unit) before the implementation that satisfies it.
4. **No surprise external dependencies.** Prefer Apple SDKs only (Foundation, Metal, AVFoundation, Accelerate). Any new dependency needs explicit approval.
5. **Swift 6 strict concurrency.** Mutable state is actor-isolated or `Sendable`; Metal command recording is `@MainActor` where the API requires it.
6. **Faithful flam3 port.** The CPU reference renderer is a faithful Swift port of flam3's algorithms (affine convention, variation formulas, ISAAC RNG + consumption order, density estimation, display pipeline) — port the logic for correctness and parity, do not approximate or reinterpret. The affine/atan bugs found via the parity oracle are the exact class of error faithful porting eliminates.
7. **License posture — owner's decision (under review).** Emberweft is currently **source-available** (PolyForm Noncommercial). Because the renderer ports flam3, the final license (including any GPL implications) is the owner's call and under review — do not assert a license constraint either way, and do not impose GPL-avoidance, until the owner decides.

## Conventions

- **Commits:** Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `perf:`, `chore:`), small and focused, branch-per-feature, PRs into `main`.
- **Formatting:** `swift-format` (config in `.swift-format`).
- **Code identifiers** use the neutral `Flame` prefix (`FlameKit`, `FlameRenderer`, …); the **brand name Emberweft** is used only for user-facing artifacts (app bundle `EmberweftApp`, screensaver `EmberweftScreenSaver`, the `emberweft` CLI).
- **Deployment target:** macOS 26 (Metal 4), Apple Silicon (M1+). Intel unsupported.
- **`genomes/`** is an intentional ~1.6 GB data-preservation archive of ~123k Electric Sheep `.flam3` genomes (gens 165–248), split into `sheep/` (stills) + `edges/` (stored transitions) + an `edges.sqlite` pair DB — do not gitignore or remove. Gen 248 is a live flock (a local launchd job `com.emberweft.sheep-sync` syncs it daily). See `genomes/README.md`.
- **M3 animation** is a faithful flam3 port. `sheep_loop` (loop) = **pure affine rotation** `R(θ)·M` (θ=blend·360°) of each xform's pre-affine 2×2 only — the **palette is static** during a loop (seamless because `R(360°)=R(0°)`; palette motion is transitions-only). `sheep_edge` (transition) = align+special-sauce-pad → rotate both → interpolate A→B with `interpolation_type=log` + HSV palette blend. See [docs/rendering/transitions.md](docs/rendering/transitions.md) and the M3 spec; treat the archived genomes (flame counts, `time` values, `edges.sqlite`) as ground truth — don't re-derive the mechanics.
- **Seamless transitions need motion blur:** `--temporal-samples 1` means *use the genome default* (≈1000, Metal-capped 64) — NOT 1 sub-pass; pass `2` for near-sharp. Low temporal → a "brutal" mid-transition morph. Proven recipe: `emberweft animate …05739… …31943… --temporal-samples 32 --frames 160 --loop-cycles 1 --backend metal` (the `/tmp/m3_mb` reference).
- **flam3 parity oracle (M3+):** not installed / no Homebrew formula — build `scottdraves/flam3` from source (autotools + zlib/libpng/libxml2), drive via **env vars** (`flam3-genome` `sequence=`/`rotate=`/`inter=` → `flam3-animate`); disable its motion blur with genome attrs `passes=1 temporal_samples=1`. On this machine the built oracle is symlinked at `~/.local/bin/flam3-*` → `~/flam3-oracle-src/flam3/` (source survives there; `/tmp` builds get evicted on reboot — re-point the symlinks if `flam3-render` goes missing). Full detail in the [M3 spec](docs/superpowers/specs/2026-07-17-m3-animation-design.md).
- **Metal↔CPU on spiky stills is Float-limited** (~33 dB on e.g. `244.00788`, under the 38 gate) — fundamental: MSL has no FP64, and double-single emulation doesn't close it (the gap is the `(x,y)` Float trajectory diverging, not color precision). CPU is the oracle (faithful to flam3); accepted, not a bug. See `docs/superpowers/plans/2026-07-23-metal-step-port.md` — **don't re-attempt a Metal STEP/double port**.

### Metal & Swift 6 gotchas
- **`.metal` files:** SwiftPM does not compile them. Bundle as `resources: [.copy("Metal")]` + `exclude: ["Metal"]`, load at runtime via `Bundle.module` + `MTLDevice.makeLibrary(source:)`.
- **Pass large structs by `thread const&`, not by value, in Metal kernels.** Passing a big read-only struct (e.g. `GPUXform`, 906 floats / 3624 B) *by value* to `static inline` helpers destabilizes the Metal compiler's FP instruction scheduling — on fragile attractors the re-scheduled Float trajectory diverges → empty `RGBA(0,0,0,0)` frames + nondeterminism (rule #2 break). This was the v0.1.2→v0.1.3 empty-frame regression (commit `938a855a2`): it passed `SpecialSauceParityTests` (single-variation) but broke real multi-xform animations. Signature fix: `f(GPUXform x, …)` → `f(thread const GPUXform& x, …)`. Not caught by fast-math toggling or struct-layout checks — it's pure codegen.
- **Metal `float` cosh/sinh/exp overflow → clamp the arg to ±88.** Metal `cosh(arg)`/`exp(arg)` overflow to `+Inf` at arg≈89/88.7 where CPU `double` is finite → `0.0f * Inf == NaN` → chaos-game trajectory collapse (v0.1.4, commit `a45ce3d6b`). 15 hyperbolic/trig/exp variations (`coth cot sinh cosh tanh sech csch csc sec exponential cosine exp sin cos tan`) clamp the overflow-prone arg to `[-88,88]` before the call — bit-identical for normal args (parity tests pass), captures CPU's saturated limit for large args. If porting a new variation using cosh/sinh/exp, apply the same clamp.
- **Variation param interpolation is per-param linear (flam3 `INTERP`), NOT "A wins".** `GenomeInterpolator.mergeLog` must interpolate each parametric field `(1−t)·a + t·b` (descriptor defaults when a side lacks the param). The old "A's params win, B fills gaps" bled A's params into the result at t=1 (v0.1.5, commit `052dcceaf`) — broke transition endpoints (`Transition(A,B,1.0)≠B`). flam3 has no `merge_log`; its variations are a fixed `var[N]` array `INTERP`'d slot-by-slot (interpolation.c:543-700).
- **GenomeInterpolator must port ALL flam3 INTERP fields, not just matrix/xform/palette.** The `blend` skeleton must interpolate (or copy-from-`cpi[0]`) every field in flam3's `INTERP` block (interpolation.c:464-700) — including the Quality display scalars (brightness, gamma, vibrancy, highlight_power, filter radii, estimator params). Any `t < 0.5 ? a : b` hard-cut or silently-dropped field is a latent transition-smoothness bug (v0.1.5: mergeLog/paletteMode; v0.1.6: Quality hard-cut).
- **The `.log` matrix det guard is intentional, not unfaithful.** Opposite-handedness xform pairs (det A·det B < 0) cross det=0 at the polar-log midpoint → singular matrix → density spike. The guard in `interpolateAffineLog` (v0.1.6) falls back to `lerpAffine` for these pairs. flam3 has the same singularity (faithful artifact); the guard is an intentional seamless divergence per the owner — don't remove it.
- **Empty/transparent Metal frames** are `RGBA(0,0,0,0)` — white in a PNG viewer, black in an alpha-flattened (`-pix_fmt yuv420p`) video. Detect via `max(pixel)==0`; isolate Metal-vs-logic by re-rendering the same frame on **CPU** (the oracle — if CPU is fine, it's Metal-specific).
- **NaN-camera archive genomes:** ~1.4% of gen-248 sheep have `center="nan nan" scale="nan"` literally in their `.flam3` headers → always render solid black on BOTH backends (data-integrity issue, not a code bug). `validate` doesn't catch it. Exclude NaN-header genomes from renders or add a defensive parser check.
- **Pipeline-state API:** use `library.makeFunction(name:)` (optional) + `device.makeComputePipelineState(function:)`. The `makeFunction("x")!.makeComputePipelineState()` form does not compile on the macOS 26 SDK.
- **`@MainActor` tests:** annotate XCTest methods `@MainActor`; don't wrap bodies in `MainActor.assumeIsolated { }` (it trips Swift 6 `SendingRisksDataRace` on `self` capture).
- **Determinism vs hashed collections:** Swift randomizes `Dictionary`/`Set` hash seeds per process, so iteration order — and thus any FP accumulation over them — is **not reproducible across launches**. For deterministic computations (rule #2), accumulate over sorted arrays; never iterate a `Dictionary`/`Set` to sum floats. (Integer-keyed `Set<Int>` and arrays are fine.)
- **Running tests:** disable the bash sandbox — `MTLCreateSystemDefaultDevice()` returns nil under it, so all Metal tests skip/fail.
- **No CI:** GitHub is a plain git mirror; the local test suite is the pre-merge gate (see [testing.md](docs/engineering/testing.md)).
- **Background subagents + swift:** a background subagent can survive `/compact` and keep spawning `swift test`/`swift build`/`xctest` processes that deadlock the `.build` lock (your own build then emits 0 bytes indefinitely). For subagent-driven swift work prefer synchronous dispatch; if a build hangs, clear orphans with `pkill -9 -f "swift-test|swift-build|xctest|swiftc"` — and don't run `swift` from the main session while a subagent is.
- **xctest block-buffers stdout when piped** (`swift test … | grep`/`tail`), so a long parity run shows 0 bytes until exit — not hung; check `ps`/CPU time for progress.
- **Parity gate runtime:** `VariationFlam3ParityTests` + `SpecialSauceParityTests` + `GoldenParityTests` is ~15–25 min; run in release (`-c release`, ~14× faster) in the background.
- **`emberweft animate` (offline) is slow** — ~6–17 s/frame at 720p, dominated by per-frame CPU thread-seed generation (scales with pixels×spp, not resolution), ~1000× slower than the realtime `FlamePlayer` engine. The fast export path is M6 work.

## Quick commands

```
swift build               # build
swift test                # run tests
swift run emberweft       # run the CLI
make build / make test    # convenience wrappers
make fetch-sheep          # archive Electric Sheep .flam3 genomes (idempotent; see genomes/README.md)
make sync-sheep           # sync NEW genomes from the live flock (gen 248)
```

## Module map (dependency direction: down)

```
FlameKit                       (genome model, .flam3 parse/serialize, interpolation)
  ├─ FlameReference            (CPU renderer: oracle + offline + fallback)
  └─ FlameRenderer             (Metal compute renderer)
       └─ FlamePlayer          (realtime adaptive playback)
            └─ FlameExport     (AVFoundation export)
EmberweftCLI                   (emberweft executable; --backend cpu|metal)
```

When unsure about scope, default to the smallest change that keeps the build green and the tests honest, and ask before large architectural moves.
