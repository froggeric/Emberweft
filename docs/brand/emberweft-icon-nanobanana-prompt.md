# Emberweft app icon — nano banana prompt

GenAI image-generation prompt for the Emberweft macOS app icon, crafted against the
design brief: legible from 16 px up, instantly recognizable, unique in the Dock,
and perception-driven (warm ember light on dark, one strong figure). Paste the
**Main prompt** into nano banana as-is; the variants are for iteration.

---

## Main prompt

A modern macOS application icon, 1024×1024, rendered as a rounded-square squircle tile filling the frame, dark app-icon style like modern macOS Sequoia-era icons: flat design with subtle dimensional depth, no gloss, no bevel outline, no drop shadow behind the tile. Aspect ratio 1:1

Subject: an abstract emblem of **woven threads of ember light**. Five to seven luminous ribbons of fire-orange and amber light sweep across the tile in a gentle interlaced weave, crossing over and under each other like threads on a loom, converging toward a softly glowing core like a banked fire. The threads are smooth, calligraphic, tapering strokes — not literal flames, not a campfire, not firewood — pure flowing lines of light with a warm gradient running along each one: deep ember red #FF3D00 at the outer ends, through vivid orange #FF6A00 and warm amber #FFB347, to pale gold #FFD98A at the glowing center.

One single thread is a cool steel blue #5B8BC9, woven among the warm ones — the quiet counterpoint that makes the mark unique.

Background: deep near-black indigo charcoal #0D1117, with an extremely subtle radial warmth behind the woven core.

Lighting and finish: the threads emit a soft bloom glow, additive like light
on a dark sensor; gentle inner depth so the weave reads as crafted cloth of fire; crisp edges, no noise, no grain, no lens effects, no sparks, no smoke.

Composition: the woven emblem is one single closed, centered figure occupying about 70% of the tile with generous margin; a bold, high-contrast silhouette that stays readable when shrunk to 16 pixels; balanced, calm, premium.

Absolutely no text, no letters, no numbers, no logo-like glyphs, no sheep, no human elements, no photographic fire, no iOS-6-style gloss or outline.

---

## Variant A — minimal single weave

A modern macOS application icon, 1024×1024 rounded-square squircle tile,
flat design with subtle depth, no gloss. One single continuous glowing thread
of ember light forms a large elegant interlaced knot or loose braid in the
center, crossing itself three times with clear over-under weave crossings.
The thread carries a warm gradient from deep ember red #FF3D00 through amber
#FFB347 to pale gold #FFD98A, with soft bloom glow on a deep charcoal-indigo
#0D1117 background. Bold silhouette, generous margins, readable at 16 pixels.
No text, no letters, no literal flame, no gloss, no sparks.

## Variant B — ember bloom mandala

A modern macOS application icon, 1024×1024 rounded-square squircle tile,
flat design with subtle depth. A radial mandala woven from thin luminous
ember-orange threads, eight woven spokes crossing over-and-under a circular
weft ring, converging into a softly glowing golden core like embers breathing
in the dark. Palette: #FF3D00, #FF6A00, #FFB347, #FFD98A threads on near-black
indigo #0D1117, one steel-blue #5B8BC9 thread woven into the ring. Calm,
symmetric, premium, crisp edges, no grain. No text, no literal fire, no gloss.

---

## Things to avoid (if the tool takes a negative prompt)

text, letters, typography, logo glyphs, sheep, wool, campfire, firewood, smoke,
sparks, photorealistic fire, lens flare, bokeh, noise, grain, gradients with
banding, iOS-6 gloss, bevels, drop shadows behind the tile, busy backgrounds,
more than eight threads, low contrast, thin hairlines that vanish at small size

## Iteration tips

- If the weave is too busy at a glance, ask for "fewer threads, thicker strokes,
  simpler crossings".
- If it looks like literal fire, ask for "abstract ribbons of light, no flames".
- If the blue thread dominates, ask for "the steel-blue thread subtle, one
  among the warm ones".

## After generation (packaging)

1. Apply the macOS squircle mask to the corners if the model rendered them
   full-bleed (or generate on a neutral solid background and mask).
2. Export the master at 1024, build the `.icns`:
   ```bash
   mkdir AppIcon.iconset
   for s in 16 32 64 128 256 512; do sips -z $s $s master.png --out AppIcon.iconset/icon_${s}x${s}.png; done
   # (plus the @2x sizes from the 1024 master)
   iconutil -c icns AppIcon.iconset -o AppIcon.icns
   ```
3. Check legibility: view the 16 px size next to other Dock icons before
   committing to the design.
