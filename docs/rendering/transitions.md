# Transitions
*Smooth morphing and animation between genomes*
> **Status:** preliminary — for review · Emberweft

## Overview

Transitions are the visual magic of fractal flames—the smooth morphing from one genome to another creates the endless, hypnotic animation that defines the Electric Sheep aesthetic. This document describes how we interpolate parameters between genomes A and B to create seamless transitions.

## The Transition Problem

Given:
- **Flame A** at time t=0 (N transforms, specific parameters)
- **Flame B** at time t=1 (M transforms, potentially different parameters)

Goal: Generate intermediate frames at t ∈ (0,1) that smoothly morph A → B.

**Challenges:**
- Different transform counts (N ≠ M)
- Different active variations
- Different camera views
- Different palettes

## Parameter Interpolation

### Interpolation Function

For most parameters, we use linear interpolation (lerp):

```
value(t) = (1 - t) · value_A + t · value_B
```

Where t ∈ [0,1] is normalized transition time.

### Edit Depth / Smooth Mode

The flam3 convention defines interpolation modes via the `smooth` attribute:

| smooth | Mode | Formula |
|--------|------|---------|
| 0 | Linear | value(t) = lerp(A, B, t) |
| 1 | Ease-in-out | value(t) = lerp(A, B, 3t² - 2t³) |
| 2 | Inverse ease | value(t) = lerp(A, B, t · (2 - t)) |

**Default:** smooth=0 (linear) for most parameters.

### Per-Parameter Interpolation

#### Affine Coefficients

Each coefficient (a, b, c, d, e, f) interpolates linearly:

```
a(t) = (1 - t) · a_A + t · a_B
b(t) = (1 - t) · b_A + t · b_B
// ... etc
```

**Note:** For coefs that represent rotations/scaling, consider quaternion-style interpolation (future enhancement).

#### Variation Weights

Variation weights also interpolate linearly:

```
weight_i(t) = (1 - t) · weight_i_A + t · weight_i_B
```

**Renormalization:** After interpolation, weights are optionally normalized:

```
total = Σ |weight_i(t)|
weight_i_normalized(t) = weight_i(t) / total
```

**Missing variations:** If a variation exists in A but not B:
- Option 1: Fade to zero: `weight_B = 0`
- Option 2: Drop from output when weight < threshold

#### Color Index

Transform color index interpolates linearly:

```
color(t) = (1 - t) · color_A + t · color_B
```

Clamped to [0,1] range.

#### Camera Parameters

**Center:**
```
center_x(t) = lerp(center_A.x, center_B.x, t)
center_y(t) = lerp(center_A.y, center_B.y, t)
```

**Scale (log-space):**
```
log_scale_A = log(scale_A)
log_scale_B = log(scale_B)
log_scale(t) = lerp(log_scale_A, log_scale_B, t)
scale(t) = exp(log_scale(t))
```

Log-space interpolation prevents unnatural "speed-ups" in zoom.

**Rotation:**
```
rotation(t) = lerp(rotation_A, rotation_B, t)
```

For shortest-path interpolation, consider angle wrapping.

#### Quality Settings

Quality parameters (filter radius, gamma, vibrancy) typically step at transition boundaries rather than interpolate:

```
quality(t) = t < 0.5 ? quality_A : quality_B
```

Or interpolate for gradual quality change (optional).

## Transform Count Mismatch

When N ≠ M (different number of transforms), we handle mismatched transforms:

### Padding with Zero-Weight Transforms

If N < M (A has fewer transforms):
```
// A's transforms
for i in 0..<N:
    interpolate(A.xforms[i], B.xforms[i], t)

// B's extra transforms
for i in N..<M:
    weight = t · B.xforms[i].weight  // Fade in from zero
    use interpolated parameters
```

If N > M (A has more transforms):
```
// Common transforms
for i in 0..<M:
    interpolate(A.xforms[i], B.xforms[i], t)

// A's extra transforms
for i in M..<N:
    weight = (1 - t) · A.xforms[i].weight  // Fade out to zero
    use interpolated parameters
```

### Threshold Culling

Transforms with weight below epsilon are excluded from rendering:

```
EPSILON = 0.001  // (preliminary)
if weight(t) < EPSILON:
    skip this transform in chaos game
```

## Final Transform Handling

If one genome has a final transform and the other doesn't:

```
if A.finalXform != nil && B.finalXform != nil:
    interpolate both
else if A.finalXform != nil:
    weight(t) = (1 - t) · A.finalXform.weight
    use A.finalXform parameters (fading out)
else if B.finalXform != nil:
    weight(t) = t · B.finalXform.weight
    use B.finalXform parameters (fading in)
else:
    no final transform
```

## Palette Interpolation

### Direct Palette Blending

Interpolate each palette entry:

```
for i in 0..<256:
    color_i(t) = lerp(palette_A[i], palette_B[i], t)
```

### Hue-Shifting

If palettes are referenced by index/hue:

```
hue_offset(t) = lerp(hue_A, hue_B, t)
palette = base_palette.shifted_hue(hue_offset(t))
```

### Crossfade Mode

For dramatically different palettes, use screen-space crossfade:

```
color_A = render(flame_A, frame)
color_B = render(flame_B, frame)
output = lerp(color_A, color_B, t)
```

This is more expensive but handles palette clashes gracefully.

## Multi-Segment Motion Genomes

Animated sequences are encoded as multiple `<flame>` elements with increasing `time` attribute:

```xml
<flame time="0.0" ...>
    <xform coefs="1 0 0 1 0 0">...</xform>
</flame>

<flame time="0.25" ...>
    <xform coefs="0.95 0 0 0.95 0 0">...</xform>
</flame>

<flame time="0.5" ...>
    <xform coefs="0.9 0 0 0.9 0 0">...</xform>
</flame>

<flame time="1.0" ...>
    <xform coefs="0.8 0 0 0.8 0 0">...</xform>
</flame>
```

**Interpolation between keyframes:**
Given time τ in [0,1], find surrounding keyframes:

```
k = floor(τ · (num_keyframes - 1))
local_t = (τ · (num_keyframes - 1)) - k

interpolate(
    keyframes[k],
    keyframes[k + 1],
    local_t
)
```

**Non-uniform timing:** If keyframes have non-uniform time spacing, find appropriate interval via binary search.

## Segment Sequencing

Playback is built from **two segment kinds** — the same two the original Electric
Sheep uses:

- **Loop** — a single sheep played through its *own* temporal keyframes (the
  `[Flame]` elements in its `.flam3`), interpolated into a seamless loop. This is
  the sheep's intrinsic motion; it does not involve any other genome. A
  single-keyframe sheep (no `time>0` keyframes) is a degenerate loop — a still
  hold. Most archived sheep are multi-keyframe loops.
- **Transition** — a morph from genome A's parameters to genome B's (the
  between-genome interpolation described in the rest of this document).

### Alternation rule (mandatory)

Loops and transitions **alternate**: `loop(A) → transition(A→B) → loop(B) →
transition(B→C) → …`. **Never two transitions in a row** — every transition is
bracketed by loops. This is how the original Electric Sheep sequences its videos,
and it is a hard constraint on the scheduler, not a suggestion.

### Endless Playback

```
loop(sheep_0) → transition(0→1) → loop(sheep_1) → transition(1→2) → … → loop(sheep_N) → transition(N→0) → loop(sheep_0) → …
```

### Segment Length

**(preliminary default):**
- Loop duration: 5.0 seconds (the sheep's own keyframe cycle, time-scaled to fit)
- Transition duration: 3.0 seconds
- Total cycle: 8.0 seconds per sheep

**Adaptive transition:** Shorter transitions for similar sheep, longer for dissimilar.

### Schedule Computation

A loop segment plays the sheep's own `[Flame]` keyframes (via FlameKit
`Interpolation`) over `loop_duration`, wrapping the last keyframe back to the
first for seamlessness. A transition segment morphs A→B over `transition_duration`.

```
current_sheep = 0
loop_end_frame       = 0 + loop_duration_frames
transition_end_frame = loop_end_frame + transition_duration_frames

for frame in 0...:
    if frame < loop_end_frame:
        # LOOP: this sheep's own temporal keyframe animation, seamless
        tau = (frame - (loop_end_frame - loop_duration_frames)) / loop_duration_frames
        render(renderSheepLoop(sheep[current_sheep], tau))   # interpolates its [Flame] keyframes
    else if frame < transition_end_frame:
        # TRANSITION: morph current -> next
        local_t = (frame - loop_end_frame) / transition_duration_frames
        render(
            interpolate(
                lastKeyframe(sheep[current_sheep]),
                firstKeyframe(sheep[(current_sheep + 1) % N]),
                local_t
            )
        )
    else:
        current_sheep = (current_sheep + 1) % N
        loop_end_frame = frame + loop_duration_frames
        transition_end_frame = loop_end_frame + transition_duration_frames
```

**Transition endpoints:** a transition starts from the *last keyframe* of sheep A
and ends at the *first keyframe* of sheep B, so the morph continues each loop's
end-state smoothly rather than jumping to an arbitrary frame.

See [playback-modes.md](../playback/playback-modes.md) for runtime scheduling.

## Determinism

For reproducible renders (offline = realtime), we fix RNG seeds:

```
seed_A = hash(genome_A.name)
seed_B = hash(genome_B.name)

for frame in transition:
    frame_seed = combine_seeds(seed_A, seed_B, frame_number)
    use_frame_seed(frame_seed)
```

**Key insight:** Same frame index always produces identical output.

## Edge Cases

### Drastic Parameter Mismatch

**Example:** Sheep A has `scale=100`, Sheep B has `scale=1000`

**Solution:**
- Log-space scale interpolation handles wide ranges
- Camera may sweep through "boring" regions—acceptable

### Conflicting Variation Sets

**Example:** A uses `sinusoidal`, B uses `julia`

**Solution:**
- Include all variations from both A and B
- Fade weights: A's variations fade out, B's fade in
- At mid-transition, both may be active

### Incompatible Palettes

**Example:** A is blue-themed, B is red-themed

**Solution:**
- Palette blending may produce muddy intermediate colors
- Use crossfade mode for cleaner transitions
- Or match hue then interpolate (advanced)

### Degenerate Transforms

**Example:** Interpolated affine becomes near-singular (determinant ≈ 0)

**Solution:**
- Add epsilon to diagonal: `a += ε, e += ε`
- Skip transform if determinant < threshold
- Warn user (may indicate bad genome)

## Quality and Performance

### Adaptive Quality During Transition

To maintain framerate during expensive transitions:

```
if frame_buffer_size > threshold:
    reduce_iterations(temporal_quality)
    reduce_filter_radius()
else:
    use_full_quality()
```

### Pre-Rendering

Cache transition frames offline for seamless playback:

```
for transition in scheduled_transitions:
    pre_render(transition, quality=HIGH)
    save_to_cache()
```

See [metal-pipeline.md](metal-pipeline.md) for compute implementation.

## Visual Quality Tips

**Smooth transitions:**
- Match camera centers between sequential sheep
- Align dominant features (rotations, symmetry)
- Harmonize color palettes (avoid clashing hues)
- Use similar variation sets across sheep in a flock

**Jarring transitions (sometimes intentional):**
- Different scales (zoom effects)
- Different color schemes (palette crossfade)
- Transform count changes (structures appear/disappear)

## Future Extensions

- **Nonlinear interpolation** — Bezier curves for parameter paths
- **Feature matching** — Align similar structures before morphing
- **Motion curves** — User-defined easing functions
- **Audio-reactive timing** — Transition sync to beat
- **Transition database** — Precomputed "good" transitions

## References

- [flame-algorithm.md](flame-algorithm.md) — Algorithm description
- [genome-format.md](genome-format.md) — Genome XML format
- [metal-pipeline.md](metal-pipeline.md) — GPU implementation
- [playback-modes.md](../playback/playback-modes.md) — Runtime sequencing
