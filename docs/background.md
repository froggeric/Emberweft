# Background
*Historical context and algorithm lineage*
> **Status:** preliminary — for review · Emberweft

## Introduction

Emberweft is a standalone native-macOS application that implements the fractal flame algorithm—the mathematical foundation of the Electric Sheep screen saver—as a modern GPU-accelerated renderer. This document traces the algorithm's history from its mathematical origins through the distributed computing phenomenon of Electric Sheep to the present-day reimplementation.

## Historical Timeline

### Iterated Function Systems (1981)

The mathematical foundation of fractal flames begins with Iterated Function Systems (IFS), formalized by John Hutchinson in 1981 and popularized by Michael Barnsley in his book *Fractals Everywhere* (1988). An IFS consists of a collection of contractive affine transformations; when iterated via the "chaos game," these transformations converge to a unique attractor set—a fractal image.

**Key paper:** Hutchinson, "Fractals and Self-Similarity" (Indiana University Mathematics Journal, 1981)

### Fractal Flame Algorithm (1992)

In 1992, Scott Draves invented the fractal flame algorithm, extending the IFS framework with three revolutionary innovations:

1. **Non-linear variations** — Each transform applies a weighted sum of non-linear functions (sinusoidal, spherical, swirl, horseshoe, …) instead of pure affine mapping
2. **Log-density display** — Rather than plotting raw hit counts, the histogram is displayed on a logarithmic scale, revealing fine detail in sparse regions that would otherwise be invisible
3. **Structural coloring** — Color is accumulated alongside spatial position during iteration (each transform carries a palette index), creating organic color patterns

A final post-pass applies a **density-estimation filter** (adaptive smoothing that widens where samples are sparse and tightens where dense) before palette lookup and tone-mapping. The algorithm produces images of unprecedented complexity and beauty, with organic, flame-like structures that gave the algorithm its name.

**Key references:**
- Draves & Reckase, "The Fractal Flame Algorithm" — [flame_draves.pdf](https://flam3.com/flame_draves.pdf)
- [Fractal flame — Wikipedia](https://en.wikipedia.org/wiki/Fractal_flame) (accessible overview)

### Electric Sheep (1999)

In 1999, Scott Draves launched Electric Sheep—a distributed computing screen saver that combined fractal flames with genetic algorithms and collaborative evolution. Inspired by SETI@home, Electric Sheep harnesses idle computers worldwide to render and evolve "sheep" (animated fractal flames).

**The innovation:** Users vote on their favorite sheep; well-voted sheep survive and breed (genetic crossover/mutation of genomes), while unpopular sheep die. This creates a Darwinian evolution of beauty.

**Technical model:**
- Central server coordinates the "flock" (genome database)
- Client computers donate idle CPU time to render frames
- Distributed rendering enables animations beyond realtime capability

Electric Sheep became a cultural phenomenon, with installations in museums, galleries, and public spaces worldwide.

**Trademarks:** Electric Sheep™ is a trademark of Scott Draves / e-dream, inc.

### Gold and HD Sheep (2000s)

As computing power increased, Electric Sheep evolved:

- **Gold sheep** — Higher-resolution renders, expanded variation set
- **HD sheep** (client by guysoft) — 1080p output, codec improvements

These iterations maintained compatibility with the original .flam3 genome format while pushing visual quality.

### Infinidream (2026)

Infinidream (formerly e-dream-ai/client) represents the next generation:

- **AI-driven evolution** — Machine learning guides sheep breeding
- **Audio reactivity** — Parameters respond to music input
- **1080p standard** — Full HD resolution with enhanced rendering
- **Modern codecs** — Efficient streaming and storage

Infinidream continues the distributed computing model while adding contemporary AI techniques.

### The content ecosystem: packs, streaming, and relaxation media

Beyond the algorithm itself, a commercial ecosystem has grown around rendered fractal flames — and it directly informs several of Emberweft's use cases:

- **Sheep Dreams (esheeper.com)** sells pre-rendered **1080p "gold sheep" packs** compatible with the Electric Sheep screensaver (no Gold subscription required to play them). Flock 711 (~800 sheep) and Flock 714 (~2080 sheep) established the model of distributing curated sheep as paid packs. © Freakie Beat Visuals; all rights reserved.
- **Stream Dreamz** (streamdreamz.vhx.tv, a Vimeo OTT channel) offers **one-hour relaxation/meditation visualizations** rendered from fractal flames — up to **4K** from "Classic Dream 58" onward, with no audio (users supply their own music). It markets them for *focused-attention meditation, self-syncing accompaniment to music, ambient eye-candy at gatherings*, and *enhancing psychedelic exploration*.

These projects validate the real-world demand for several Emberweft goals: **long-form (hour+) export, multi-resolution up to 4K, endless playback, and music-accompaniment/meditation use cases.** They are also **commercial, all-rights-reserved derivative works** — a reminder that rendered flame videos and curated packs carry their own licensing (see [license-and-attribution.md](license-and-attribution.md)).

## Emberweft: A Standalone Reimplementation

Emberweft is a **clean-sheet, independent implementation** of the fractal flame algorithm designed for modern Apple Silicon hardware:

**Relationship to Electric Sheep:**
- **Standalone** — No dependency on the Electric Sheep server or infrastructure
- **Format-compatible** — Reads and writes standard .flam3 genome XML
- **No network requirement** — All rendering is local
- **Optional flock import** — Future support for importing genomes from Electric Sheep server (not required for operation)

**Technical independence:**
- Own renderer (Metal-based, not derived from flam3 C code)
- Own genome parser (Swift, not derived from flam3)
- Native macOS architecture (no POSIX dependencies)
- Swift 6 strict concurrency for thread safety

**Creative positioning:**
Emberweft brings fractal flames to the Apple ecosystem with:
- Native Apple Silicon acceleration (Metal 4)
- Standalone creative tool (not just a screen saver)
- High-quality export for video professionals
- Interactive exploration and editing

## Credits and Lineage

**Algorithm and original implementation:**
- Scott Draves — fractal flame algorithm (1992)
- Scott Draves and contributors — flam3 reference renderer (C)
- Electric Sheep community — genome database and evolution

**Trademark notice:**
- Electric Sheep™ and Infinidream™ are trademarks of Scott Draves / e-dream, inc.
- Emberweft is not affiliated with or endorsed by these entities

**Academic foundation:**
- John Hutchinson — IFS formalization (1981)
- Michael Barnsley — IFS popularization (1988)

## Reference Projects

| Project | Description | URL |
|---------|-------------|-----|
| **flam3** | Reference C renderer, .flam3 format definition | https://github.com/scottdraves/flam3 |
| **electricsheep** | Original distributed screen saver client | https://github.com/scottdraves/electricsheep |
| **e-dream-ai/client** | Infinidream client with AI evolution | https://github.com/e-dream-ai/client |
| **electricsheep-hd-client** | HD client by guysoft for 1080p rendering | https://github.com/guysoft/electricsheep-hd-client |
| **Fractorium** | OpenCL-based flame editor (Windows/Linux/macOS) | https://github.com/tcoctz/Fractorium |
| **IFSRenderer** | iOS fractal flame renderer | https://github.com/luiseduardom/IFSRenderer |
| **shader-playground** | Experimental GPU fractal flame shaders | https://github.com/chadfurman/shader-playground |
| **Sheep Dreams (esheeper.com)** | Commercial 1080p gold-sheep pack distributor | https://esheeper.com |
| **Stream Dreamz** | Hour-long relaxation/meditation flame videos (up to 4K) | https://streamdreamz.vhx.tv |
| **Electric Sheep — Wikipedia** | Historical/technical overview & references | https://en.wikipedia.org/wiki/Electric_Sheep |
| **Fractal flame — Wikipedia** | Algorithm overview & notation | https://en.wikipedia.org/wiki/Fractal_flame |
| **electricsheep.org** | Original project site | https://electricsheep.org |
| **infinidream.ai** | Current-generation service | https://infinidream.ai |

## Algorithm Summary

The fractal flame algorithm generates images by:

1. **Define a set of transforms** — Each transform combines an affine matrix with non-linear variations
2. **Iterate via chaos game** — Randomly choose a transform, apply it to the current point, repeat
3. **Accumulate histogram** — Track point visits and color in a spatial grid
4. **Filter density** — Adaptive smoothing to reduce noise while preserving detail
5. **Map to pixels** — Log-density alpha, palette lookup, tone-mapping to final image

For animation, transforms morph smoothly over time, creating organic motion.

See [flame-algorithm.md](rendering/flame-algorithm.md) for rigorous mathematical description.

## Why a Native Implementation?

Modern hardware enables realtime rendering that was impossible when Electric Sheep launched:

- **Apple Silicon GPU** — Metal 4 compute shaders enable 60+ FPS at 1080p
- **Local rendering** — No network latency; instant interactive response
- **Creative control** — Direct genome manipulation for artists
- **Archive independence** — Your sheep library is yours forever

Emberweft honors the algorithm's heritage while building for the future of fractal art on Apple platforms.
