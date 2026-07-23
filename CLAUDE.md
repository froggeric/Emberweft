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
- **flam3 parity oracle (M3+):** not installed / no Homebrew formula — build `scottdraves/flam3` from source (autotools + zlib/libpng/libxml2), drive via **env vars** (`flam3-genome` `sequence=`/`rotate=`/`inter=` → `flam3-animate`); disable its motion blur with genome attrs `passes=1 temporal_samples=1`. On this machine the built oracle is symlinked at `~/.local/bin/flam3-*` → `~/flam3-oracle-src/flam3/` (source survives there; `/tmp` builds get evicted on reboot — re-point the symlinks if `flam3-render` goes missing). Full detail in the [M3 spec](docs/superpowers/specs/2026-07-17-m3-animation-design.md).

### Metal & Swift 6 gotchas
- **`.metal` files:** SwiftPM does not compile them. Bundle as `resources: [.copy("Metal")]` + `exclude: ["Metal"]`, load at runtime via `Bundle.module` + `MTLDevice.makeLibrary(source:)`.
- **Pipeline-state API:** use `library.makeFunction(name:)` (optional) + `device.makeComputePipelineState(function:)`. The `makeFunction("x")!.makeComputePipelineState()` form does not compile on the macOS 26 SDK.
- **`@MainActor` tests:** annotate XCTest methods `@MainActor`; don't wrap bodies in `MainActor.assumeIsolated { }` (it trips Swift 6 `SendingRisksDataRace` on `self` capture).
- **Determinism vs hashed collections:** Swift randomizes `Dictionary`/`Set` hash seeds per process, so iteration order — and thus any FP accumulation over them — is **not reproducible across launches**. For deterministic computations (rule #2), accumulate over sorted arrays; never iterate a `Dictionary`/`Set` to sum floats. (Integer-keyed `Set<Int>` and arrays are fine.)
- **Running tests:** disable the bash sandbox — `MTLCreateSystemDefaultDevice()` returns nil under it, so all Metal tests skip/fail.
- **No CI:** GitHub is a plain git mirror; the local test suite is the pre-merge gate (see [testing.md](docs/engineering/testing.md)).
- **Background subagents + swift:** a background subagent can survive `/compact` and keep spawning `swift test`/`swift build`/`xctest` processes that deadlock the `.build` lock (your own build then emits 0 bytes indefinitely). For subagent-driven swift work prefer synchronous dispatch; if a build hangs, clear orphans with `pkill -9 -f "swift-test|swift-build|xctest|swiftc"` — and don't run `swift` from the main session while a subagent is.
- **xctest block-buffers stdout when piped** (`swift test … | grep`/`tail`), so a long parity run shows 0 bytes until exit — not hung; check `ps`/CPU time for progress.
- **Parity gate runtime:** `VariationFlam3ParityTests` + `SpecialSauceParityTests` + `GoldenParityTests` is ~15–25 min; run in release (`-c release`, ~14× faster) in the background.

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
