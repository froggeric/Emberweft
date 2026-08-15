# Emberweft App Icon — "Ember Loop"

The macOS application icon for Emberweft: a ring braided from three glowing
ember threads, seen against a deep indigo night, with a hearth burning far
inside the loop.

```
      ● ← coal node on the hot arc
   ╭──────╮
  │ ╭────╮ │      hot arc (top-right): pale gold / orange
  │ │ ◉  │ │      hearth: white-hot kernel in a dark void
  │ ╰────╯ │      cool arc (bottom-left): deep maroon
   ╰──────╯
```

* [The concept](#the-concept)
* [Concept evaluation](#concept-evaluation)
* [Color palette](#color-palette)
* [Size legibility findings](#size-legibility-findings)
* [Iteration story](#iteration-story)
* [Files](#files)
* [Re-running the generator](#re-running-the-generator)

## The concept

**Ember + weft.** The name is two words, and the icon is those two words
composed into one form:

* ***Weft*** is the horizontal thread woven across the warp. The ring is
  braided — three thick threads that visibly pass **over and under** each
  other (each crossing has a contact shadow; each thread has cylindrical
  shading: dark edge, bright core, thin specular line). The weave is the
  differentiator: it is what makes this icon *not* a generic flame, *not* a
  generic spiral, and not derivative of the Electric Sheep mark.
* ***Ember*** is the light. The threads are dyed along a coal ramp: deep
  maroon at the lower-left, rust, ember orange, amber, pale gold toward the
  upper-right. The ring is hottest where it faces the light of the hearth.
* **The hearth.** Inside the loop there is no letterform and no object — just
  a dark void with a small, deep, white-orange glow far inside it. The eye
  completes the ring and is drawn to the center; nothing is spelled out.
  This is the "slightly mysterious" note.
* **The loop.** A closed ring, not an open swoosh. Emberweft's product is
  seamless ambient *loops*; the icon closes the way the playback does. A
  closed form is also the strongest possible gestalt (closure + continuity),
  which is exactly what a 16 px Dock tile needs.

## Concept evaluation

Four concepts were developed; three were rendered (concept D was rejected on
paper). Evaluation against the owner's four criteria:

| # | Criterion | A — Ember Loop (braided ring) ✅ | B — Rising Weft (diagonal braid) | C — Loom Plaque (woven diamond) | D — Woven flame |
|---|---|---|---|---|---|
| 1 | Visibility at 16→1024 | **Strong.** A donut is a preattentive shape; the hole survives 16 px (dark center vs warm ring). Shipped 16/32 use a pixel-dedicated rendition. | Weak at 16: a diagonal band ~2 px wide reads as a smear. | Medium: diamond silhouette reads, but the weave vanishes below 64. | Medium. |
| 2 | Ease of recognition | **Strong.** One form (ring), one story (braided fire), high-contrast core (hot arc). | Medium: reads as "a braid" but is an open, directional form — less instantly nameable. | Medium: instantly "woven", but says textile/craft more than fire. | Trap: at 16 px it is just a flame — the generic case the brief excludes. |
| 3 | Uniqueness | **Strong.** No Dock neighbor is a braided torus of ember light; not Apple-adjacent; no stock flame/spiral/orb. | Good, but diagonal-ribbon icons exist. | Medium: plaque/quilt-like icons exist; reads as a fabric app. | Fails: "not a generic flame" is an explicit exclusion. |
| 4 | Human perception | **Strong.** Ember warmth (energy/comfort) on near-black indigo; orange-vs-indigo figure-ground is a maximum-contrast pair; the ring closes (gestalt); no complementary-edge vibration (all warm-on-dark, one dim violet counterpoint). | Good warmth, but the open form does not close — the brief asks that the weave close into a whole. | Good, but cooler overall (violet warp reads first at a glance). | Warm, but flame-red-on-dark is the most common hot-app cliché. |

**Chosen: A — Ember Loop.** It is the only concept that scores strong on all
four criteria, and it carries the product's core metaphor (the seamless loop)
rather than a decoration.

## Color palette

| Role | Hex | Notes |
|---|---|---|
| Ground edge | `#0A0711` | near-black indigo, squircle corners fall to this |
| Ground mid | `#150E22` | |
| Ground center | `#251734` | faintly warm — the hearth's ambient light |
| Loom threads (backdrop) | `#362D50` @ ~10 % | the dim warp behind the ring |
| Thread: deep maroon | `#751C17` | cool arc, bottom-left |
| Thread: rust | `#A32914` | |
| Thread: ember orange | `#E05717` | |
| Thread: amber | `#FC8A21` → `#FFB342` | hot arc |
| Thread: pale gold | `#FFD47A` | hottest highlight threads (never pure white) |
| Hearth glow | `#FF6B24` → transparent | inside the loop |
| Hearth kernel | `#FFEBB8` | the white-hot dot at the center |
| Rim hairline | `#9E8FD9` @ 16 % | keeps the dark icon off a dark Dock's edge |

Exact values live in the ember ramp + ground stops in `generate_icon.swift`
(`emberStops`, `drawGround`); the hexes above are the 8-bit sRGB roundings of
those ramp endpoints.

## Size legibility findings

Measured on the committed `contact-sheet.png`:

* **512 / 256** — full braid detail, hot/cool arc gradient, hearth, coal
  nodes, sparks, loom backdrop all resolve. No blowout, no banding.
* **128** — the weave reads clearly; sparks/loom drop below perception
  (intended).
* **64** — the braided texture first becomes visible ("segmented" ring);
  this is the smallest size where the weave is a brand signal.
* **32** — reads as a warm woven ring with a dark hole. Texture absent
  (physically impossible at this size without noise).
* **16** — reads as a warm donut with a dark center. The plain master
  downscale turns to mud here, so the shipped 16 (and 32, and 16@2x) come
  from a **pixel-dedicated small rendition** (`RingConfig.small()`):
  3 chunkier threads (wider, 6 lobes instead of 7), brighter tonal floor,
  less bloom, darker hole, no loom/sparks. Same mark, same palette — the
  shape survives.
* **Light Dock** — the dark squircle holds its silhouette on a light
  background from 16 px up (checked on the light strip of the contact
  sheet); the hairline rim prevents edge-melt on dark Docks.

## Iteration story

The evolution (each step driven by looking at renders, contact sheets, and
zoomed crops — never by theory alone):

1. **v1 — concepts.** All three concepts rendered side by side. Findings:
   the ring's 5-strand weave read as *mush* (no visible interlace), the hot
   arc was blown out, B (diagonal braid) read as a "tail", C (diamond) was
   cleanest but said "textile app". Ring kept; B and C dropped.
2. **v2 — first fixes.** Contact shadows added under over-thread crossings,
   4 strands, dither, glow pullback. Still mush. Two root causes found:
   *(a)* every strand shared the same color at a given angle (heat was
   angle-only), so crossings had no color contrast; *(b)* the wide bloom
   tiers blurred the band's silhouette, which *fills the gaps between
   strands* with light.
3. **v3 — structural fix.** Per-strand **dye offsets** (each thread is a
   step colder/hotter on the ramp, so threads differ everywhere including at
   crossings), tonal window clamped off white and off black, bloom tiers
   lowered further, premultiplied-alpha bug in the ground dither fixed (it
   had been a light haze, not dither), hearth strengthened. A 2× zoom crop
   confirmed real over-under interlace with contact shadows and cylindrical
   shading. But the contact sheet showed **16–32 px was a warm blob** — the
   bloom and center glow filled the donut hole at tiny sizes.
4. **v4 — small sizes.** Bolder geometry + a pixel-dedicated small
   rendition (no loom/sparks, chunky threads, darker hole). 16 px became a
   crisp donut. Critique then flagged the 4-strand band as "solidly filled /
   busy".
5. **v5 — the A/B.** 3 strands (thicker, wider swing) vs 4, rendered side
   by side at 512 + 16. The 3-strand won every axis: clearer braid, calmer
   at 512, more legible at 128, better 16 px. Adopted as default; center
   glow trimmed. Final reviews of the 1024 master and the contact sheet:
   SHIP. Determinism verified: two runs produce byte-identical PNGs
   (SHA-256 `580f60c7…`).

## Files

| File | Purpose |
|---|---|
| `generate_icon.swift` | the deterministic generator (all three concepts + master + small rendition + contact sheet) |
| `master-1024.png` | the 1024×1024 master (squircle, transparent corners) |
| `contact-sheet.png` | size-legibility evidence (16→512 dark, 16→256 light, shipped 16/32/64) |
| `../../Assets/AppIcon.icns` | the shippable icon set (16…512 + @2x) |

## Re-running the generator

```sh
swift Tools/AppIcon/generate_icon.swift --concept ring --out /tmp/master-1024.png --size 1024
swift Tools/AppIcon/generate_icon.swift --concept ring --small  --out /tmp/small-256.png   --size 256
swift Tools/AppIcon/generate_icon.swift --contact /tmp/master-1024.png \
       --contact-small /tmp/small-256.png --out /tmp/contact-sheet.png
```

Rebuilding the `.icns` (small rendition feeds 16/16@2x/32; the master feeds
64 and up):

```sh
cd /tmp && rm -rf AppIcon.iconset && mkdir AppIcon.iconset
sips -z 16 16 small-256.png --out AppIcon.iconset/icon_16x16.png
sips -z 32 32 small-256.png --out AppIcon.iconset/icon_16x16@2x.png
sips -z 32 32 small-256.png --out AppIcon.iconset/icon_32x32.png
sips -z 64 64 master-1024.png --out AppIcon.iconset/icon_32x32@2x.png
sips -z 128 128 master-1024.png --out AppIcon.iconset/icon_128x128.png
sips -z 256 256 master-1024.png --out AppIcon.iconset/icon_128x128@2x.png
sips -z 256 256 master-1024.png --out AppIcon.iconset/icon_256x256.png
sips -z 512 512 master-1024.png --out AppIcon.iconset/icon_256x256@2x.png
sips -z 512 512 master-1024.png --out AppIcon.iconset/icon_512x512.png
cp master-1024.png AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns AppIcon.iconset -o /path/to/repo/Assets/AppIcon.icns
```

Variant knobs for exploring without editing code (all deterministic):

```sh
swift Tools/AppIcon/generate_icon.swift --out /tmp/v.png --size 512 \
  --strands 3 --lobes 7 --radius 292 --amp 66 --width 40 \
  --heat-angle 45 --glow 1.0 --seed 7
```

Notes for whoever wires this into the app bundle: the `.icns` lives at
`Assets/AppIcon.icns` (repo root `Assets/`, intentionally outside
`Sources/`); reference it from the app's `Info.plist` via
`CFBundleIconFile` = `AppIcon` (or `ASSETCATALOG` flow) when the dist-bundle
work lands.
