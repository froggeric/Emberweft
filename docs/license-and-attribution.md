# License & Attribution

*Licensing policy, trademark acknowledgments, and attribution requirements.*

> **Status:** preliminary — for review · Emberweft

## Summary

| Asset | License |
|---|---|
| **Emberweft source code** | **PolyForm Noncommercial 1.0.0** (source-available) |
| **Curated seed library** (shipped genomes + metadata) | **CC-BY-NC 4.0** (Creative Commons Attribution-NonCommercial) |
| **Rendered outputs** | Owned by the user; commercial production requires a commercial license (see below) |

Emberweft is **source-available**, not "open source" in the OSI sense — the PolyForm Noncommercial license permits anyone to read, study, use, modify, and redistribute the source **for noncommercial purposes**, while reserving commercial use. See [Why PolyForm Noncommercial?](#why-polyform-noncommercial) below.

## Trademark Acknowledgments

**"Electric Sheep"** and **"Infinidream"** are trademarks of Scott Draves and e-dream, inc.

The fractal flame algorithm was created by Scott Draves in 1992 and has been implemented in numerous projects over the decades, including the original Electric Sheep screensaver and the contemporary Infinidream service.

Emberweft is an **independent, standalone re-implementation** of the fractal flame algorithm. It is:

- **NOT** affiliated with, endorsed by, or derived from the Electric Sheep or Infinidream source code
- **NOT** connected to Electric Sheep or Infinidream servers or services
- **NOT** authorized to use the "Electric Sheep" or "Infinidream" trademarks in its name or branding

References to Electric Sheep or Infinidream in this documentation are for historical context and description only, under nominative fair use.

## Code License — PolyForm Noncommercial 1.0.0

The Emberweft source code is licensed under the [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/).

**What everyone may do (noncommercially):** read, study, run, modify, and redistribute the source, including for personal, educational, academic, and hobby use.

**What requires a commercial license:** any use of Emberweft (or a derivative) for commercial advantage or monetary compensation — for example selling the app, offering a paid relaxation/streaming service built on it, rendering content for paying clients, or bundling it in a commercial product.

### Why PolyForm Noncommercial?

- **Reserves commercial value for the author** while keeping the source freely available for the fractal-art, education, and hobby communities.
- **Honest about intent.** A noncommercial license is a deliberate choice, not an oversight — it matches a possible future of a paid Emberweft app or service (mirroring how the ecosystem already splits into free tools and commercial content like Sheep Dreams / Stream Dreamz).
- **Drafted by professionals**, SPDX-identified (`PolyForm-Noncommercial-1.0.0`), and unambiguous about the noncommercial boundary.

### Dual licensing (planned)

The intended pattern is **dual-licensed**: PolyForm-Noncommercial for the public source, plus a separate **commercial license** available to paying customers. Setting this up costs nothing now and keeps the commercial door open; the commercial-license text will be added when needed.

### Contributor License Agreement (CLA) — required before external contributions

Because the project is noncommercial-licensed, **outside contributions must be governed by a CLA** that grants the maintainer the commercial rights to contributed code. Without it, each contributor's Noncommercial restriction sticks to their changes and can block the maintainer's own commercial release.

- **Solo-authored work (now):** no CLA needed.
- **The day the first external pull request is accepted:** a CLA must be in place first. See `CONTRIBUTING.md`.

### "Source-available," not "open source"

PolyForm Noncommercial is **not** approved by the Open Source Initiative (OSI), because OSI's definition forbids field-of-use restrictions such as "noncommercial." Calling Emberweft "open source" would be inaccurate. The correct term is **"source-available"** (sometimes "fair-code"). This wording is used throughout our documentation.

> This is a plain-language summary, not legal advice. The authoritative terms are the [PolyForm Noncommercial 1.0.0 license text](https://polyformproject.org/licenses/noncommercial/1.0.0/) and the `LICENSE` file in the repository root.

## Content License — CC-BY-NC 4.0

The curated seed library shipped with Emberweft (genome files + their metadata) is licensed under [Creative Commons Attribution-NonCommercial 4.0](https://creativecommons.org/licenses/by-nc/4.0/).

**Why CC-BY-NC (not CC-BY):** the broader CC-BY-4.0 license *allows* commercial reuse, which would undercut Emberweft's noncommercial intent. CC-BY-NC keeps the curated library noncommercial too, while still allowing sharing, remixing, and attribution-given reuse for noncommercial purposes.

Each genome in the [Seed Library](library/seed-library.md) carries metadata fields for:

- Original creator (if known)
- Source (e.g., "Electric Sheep flock #1234", "hand-authored by X")
- License of the source genome
- Any modifications made

### Per-Genome Attribution

Respecting the provenance of mathematical parameters is ethically important even where it is legally ambiguous. Emberweft will:

- Store creator and source information in genome metadata
- Display attribution when a genome is rendered or exported
- Let users view and edit this metadata
- Respect any licenses attached to imported genomes

## Genome Reuse and Redistribution

Genomes exist in a legal gray area — they are parameter sets, not expressive works. Emberweft takes a conservative, respectful approach.

### Importing Genomes

When users import genomes from external sources (Electric Sheep flocks, flam3 collections, community archives), Emberweft will:

- Preserve any existing license and attribution metadata
- Warn if a genome's license restricts redistribution
- Store source information in its internal metadata format

### Redistributing Genomes

Emberweft does not redistribute genomes whose licenses prohibit redistribution:

- **Electric Sheep flock genomes:** carry their own licensing terms; any bulk-redistribution restrictions are respected, while individual users may import genomes they have the right to access.
- **CC-licensed genomes:** the specific terms (BY, SA, NC, ND) are respected and surfaced to users.
- **Public domain:** clearly marked and freely redistributable.

### Rendered Outputs

> **Note — commercial derivatives exist.** The fractal-flame ecosystem includes **commercial, all-rights-reserved** products built on rendered sheep — e.g. **Sheep Dreams (esheeper.com)** sells paid 1080p gold-sheep packs, and **Stream Dreamz** sells hour-long relaxation videos up to 4K. Their *videos and pack compilations* are copyrighted works you may not redistribute. Emberweft ships only its *own* curated, properly-licensed genomes and never bundles content from these services.

**Who owns a render?** The user owns the *output files* they produce. **But** commercial use of Emberweft itself — including rendering outputs for commercial purposes — is governed by the PolyForm Noncommercial license: producing content for commercial advantage requires a commercial license, even if the production itself is automated. Noncommercial renders may be freely used and shared noncommercially.

This aligns with generative-art norms: the algorithm's creator deserves recognition, and the user's compute and creative choices produce a new work — while the tool's own commercial-use boundary is respected.

## Using flam3 as a development-only oracle

The reference C implementation [flam3](https://github.com/scottdraves/flam3) is **GPL-family** licensed. Emberweft uses flam3 **only as an external, dev-only oracle** — installed via Homebrew on a developer's machine to generate golden reference images for testing. It is **never linked into, bundled with, or distributed as part of Emberweft**, and its source is not copied into this repository. This keeps Emberweft's PolyForm-Noncommercial license completely independent of flam3's GPL terms. See [development-approach.md](engineering/development-approach.md).

## Third-Party References

These projects are studied for design and algorithm understanding. They are **not bundled** with Emberweft, and no code is derived from them:

| Project | Type | Role |
|---------|------|------|
| **flam3** | C renderer & tools | Reference implementation of the algorithm; genome-format spec; dev-only golden oracle |
| **Fractorium** | C++/Qt editor | UI/UX reference for flame editing workflows |
| **IFSRenderer** | Metal implementation | Technical reference for GPU flame rendering |
| **scottdraves/electricsheep** (GitHub) | Original screensaver | Historical reference, flock-protocol understanding |
| **e-dream-ai/client** (GitHub) | Infinidream client | Contemporary architecture reference |
| **guysoft/electricsheep-hd-client** (GitHub) | Community fork | Alternative implementation approaches |
| **electricsheep.org** · **infinidream.ai** | Services | Ecosystem context |

## Attribution in Generated Content

While not always legally required, users are encouraged to credit sources where appropriate:

### Screenshots / shared stills
```
Generated with Emberweft · fractal flame algorithm by Scott Draves
```

### Exported videos
```
Made with Emberweft
Visuals: fractal flame algorithm by Scott Draves
```

### Music videos (audio-reactive)
```
Made with Emberweft
Audio-reactive visuals: fractal flame algorithm by Scott Draves
```

### Academic / educational use
> The fractal flame algorithm was created by Scott Draves in 1992. This implementation is part of Emberweft, an independent re-implementation for modern macOS and Apple Silicon hardware.

## Licensing Milestones

| Phase | Action |
|-------|--------|
| M0 (Current) | Licenses chosen; `LICENSE` (PolyForm-NC) + `LICENSE-SEEDS` (CC-BY-NC) to be committed at repo bootstrap |
| M1 | License headers on all source files; seed-library metadata schema with attribution |
| Pre-first-external-PR | CLA in place (`CONTRIBUTING.md`) |
| As needed | Commercial-license text added (dual licensing) |

## Questions and Feedback

Questions about licensing, attribution concerns, or interest in a commercial license: open an issue in the repository, or contact the maintainer.

Emberweft is committed to respecting the intellectual property of the original creators, providing clear licensing for its own contributions, and maintaining transparent attribution throughout.

---

*This is a plain-language summary and not legal advice. Authoritative terms live in the `LICENSE` and `LICENSE-SEEDS` files and the upstream license texts they reference.*
