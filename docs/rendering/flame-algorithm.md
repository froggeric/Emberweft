# Fractal Flame Algorithm
*Mathematical foundation of the rendering system*
> **Status:** preliminary — for review · Emberweft

## Overview

The fractal flame algorithm is an extension of Iterated Function Systems (IFS) that produces organic, flame-like images through nonlinear variations and structural coloring. This document provides a rigorous mathematical description for engineers implementing the algorithm.

## Notation

| Symbol | Meaning |
|--------|---------|
| x_n = (x, y) | Point in 2D plane at iteration n |
| F_i | i-th transform function (i = 1..N) |
| p_i | Selection probability for transform i (Σp_i = 1) |
| a_i, b_i, c_i, d_i, e_i, f_i | Affine coefficients for transform i |
| V_j | j-th variation function (non-linear) |
| w_{i,j} | Weight of variation j in transform i |
| H[u,v] | Histogram accumulator at grid position (u,v) |
| C_i | Color index associated with transform i |
| Palette(c) | RGB color lookup at palette index c ∈ [0,1] |

## Iterated Function Systems

### Basic IFS

An Iterated Function System consists of N contractive transforms {F_1, ..., F_N}. Starting from an arbitrary point x_0, we generate a sequence by:

1. Choose transform i with probability p_i
2. Apply transform: x_{n+1} = F_i(x_n)
3. Repeat for many iterations

The resulting sequence converges to a unique attractor set—the fractal image.

### Standard Affine Transform

In traditional IFS, each transform is a 2D affine transformation. The
`coefs = "a b c d e f"` string is laid out as the matrix
`| a c e |` / `| b d f |` (matching flam3 `parser.c:974` and
`variations.c:2145`):

```
F_i(x) = [x']   [a_i  c_i  e_i] [x]
        [y'] = [b_i  d_i  f_i] [y]
                                   [1]
```

Or equivalently:
- x' = a_i · x + c_i · y + e_i
- y' = b_i · x + d_i · y + f_i

Contractivity requires that the matrix eigenvalues have magnitude < 1.

## The Fractal Flame Extension

### Variations

The fractal flame algorithm replaces the affine transform with a weighted sum of **variations**—non-linear functions that warp space in interesting ways:

```
F_i(x) = Σ_{j=1 to M} w_{i,j} · V_j(x)   +   (optional affine post-transform)
```

Where:
- w_{i,j} is the weight of variation j in transform i
- V_j is the variation function
- The affine post-transform applies after all variations

The weights w_{i,j} are typically normalized: Σ_j |w_{i,j}| = 1 (or near 1).

### Common Variations

**Linear (identity):**
```
V_linear(x, y) = (x, y)
```

**Sinusoidal:**
```
V_sinusoidal(x, y) = (sin(x), sin(y))
```

**Spherical:**
```
r² = x² + y²
V_spherical(x, y) = (x / r², y / r²)
```

**Swirl:**
```
r² = x² + y²
V_swirl(x, y) = (x·sin(r²) - y·cos(r²), x·cos(r²) + y·sin(r²))
```

**Horseshoe:**
```
r = sqrt(x² + y²)
V_horseshoe(x, y) = ((x - y)·(x + y) / r, 2xy / r)
```

**Polar:**
```
r = sqrt(x² + y²), θ = atan2(y, x)
V_polar(x, y) = (θ / π, r - 1)
```

**Heart:**
```
r = sqrt(x² + y²), θ = atan2(y, x)
V_heart(x, y) = (r·sin(θ)·r·cos(θ), r·cos(θ))
```

**Disc:**
```
r = sqrt(x² + y²), θ = atan2(y, x)
V_disc(x, y) = (θ·sin(πr) / π, θ·cos(πr) / π)
```

**Spiral:**
```
r = sqrt(x² + y²), θ = atan2(y, x)
V_spiral(x, y) = ((cos(θ) + sin(r)) / r, (sin(θ) - cos(r)) / r)
```

**Hyperbolic:**
```
r = sqrt(x² + y²), θ = atan2(y, x)
V_hyperbolic(x, y) = (sin(θ) / r, r·cos(θ))
```

**Diamond:**
```
r = sqrt(x² + y²), θ = atan2(y, x)
V_diamond(x, y) = (sin(θ)·cos(r), cos(θ)·sin(r))
```

**Ex:**
```
r = sqrt(x² + y²), θ = atan2(y, x)
V_ex(x, y) = (sin(θ + r)·sin(r), sin(θ - r)·cos(r))
```

**Julia:**
```
r = sqrt(x² + y²), θ = atan2(y, x)
V_julia(x, y) = (r·cos((⌊r⌋ + 1)·θ), r·sin((⌊r⌋ + 1)·θ))
```

Many more variations exist; the reference flam3 renderer implements 50+.

### Affine Pre- and Post-Transforms

Each transform has an optional affine pre-transform (applied before variations) and post-transform (applied after variations):

```
x' = pre_affine(x)
x'' = Σ_j w_j · V_j(x')
x''' = post_affine(x'')
```

The post-transform is particularly important for controlling overall shape and scale.

### Final Transform

An optional **final transform** is applied after every iteration, regardless of which transform was chosen:

```
x_{n+1} = post_affine_final( Σ_j w_{final,j} · V_j( pre_affine_final(x_n) ) )
```

The final transform typically has weight=0 (not selected in chaos game) but applies to every point, useful for global warping effects.

## The Chaos Game Algorithm

### Iteration Loop

Starting from a random point x_0 (or fixed seed), iterate:

```
for n = 1 to ITERATIONS:
    # Choose transform by probability p_i
    i = choose_transform(p_1, ..., p_N)

    # Apply transform
    x_n = F_i(x_{n-1})

    # Skip first few iterations (attractor convergence)
    if n < FUSE:
        continue

    # Map to histogram coordinates
    (u, v) = world_to_grid(x_n)

    # Accumulate histogram
    H[u, v].count += 1
    H[u, v].color += blend_color(C_i, running_color)
```

### World-to-Grid Mapping

The point (x, y) is mapped to histogram bin (u, v):

```
center = (cx, cy)      # Camera center in world coordinates
scale = pixels_per_unit / zoom
rotation = camera_angle

# Rotate and scale relative to center
x' = (x - cx) · cos(rotation) - (y - cy) · sin(rotation)
y' = (x - cx) · sin(rotation) + (y - cy) · cos(rotation)

# Apply scale
x'' = x' · scale
y'' = y' · scale

# Map to bin coordinates (with offset to grid center)
u = floor(x'' + width / 2)
v = floor(y'' + height / 2)
```

### Fusing

The first FUSE iterations (typically 10-20) are discarded to allow the sequence to converge to the attractor. This avoids including transient points not on the attractor.

## Structural Coloring

### Color Accumulation

Each transform carries a color index C_i ∈ [0, 1]. During iteration, we maintain a running color that blends toward the current transform's color:

```
running_color = (1 - α) · running_color + α · C_i
```

Where α is a small blend factor (typically 0.1-0.5). This causes colors to "flow" through the attractor structure.

### Palette Lookup

The final color for a histogram bin is obtained by mapping the accumulated color index to a palette:

```
final_color = Palette(running_color)
```

The palette is a 1D lookup table (256 entries typical) defining RGB values at positions 0-1.

### Color Coordinates

When storing color in the histogram, we accumulate RGB components directly:

```
H[u, v].color.r += Palette(running_color).r
H[u, v].color.g += Palette(running_color).g
H[u, v].color.b += Palette(running_color).b
```

Later, we normalize by count to get average color.

## Histogram Accumulation

### Bin Structure

Each histogram bin stores:

```c
struct Bin {
    float count;      // Number of points landing here
    float color_r;    // Sum of red components
    float color_g;    // Sum of green components
    float color_b;    // Sum of blue components
}
```

### Atomic Accumulation

In parallel implementations (GPU), multiple threads may write to the same bin simultaneously. Atomic operations ensure correct accumulation:

```metal
atomic_fetch_add(&histogram[bin_index].count, 1);
atomic_fetch_add(&histogram[bin_index].color_r, color.r);
atomic_fetch_add(&histogram[bin_index].color_g, color.g);
atomic_fetch_add(&histogram[bin_index].color_b, color.b);
```

Alternative strategies include privatized per-thread histograms merged later.

## Density Estimation

### The Problem

Raw histogram data is noisy: bins have varying sample counts, creating grainy artifacts. We need a filter that:
- Smooths noise in sparse regions
- Preserves detail in dense regions

### Adaptive Kernel

The density estimation filter uses an adaptive kernel radius based on local sample density:

```
radius = estimator_radius · sqrt(estimator_minimum / (count + estimator_minimum))
```

Where:
- `estimator_radius` — Base filter radius **(preliminary default: 10-20 pixels)**
- `estimator_minimum` — Floor to prevent division by zero **(preliminary default: 1-5)**
- `count` — Bin count (density)

In sparse regions (low count), the radius widens, averaging over more neighbors. In dense regions (high count), the radius tightens, preserving fine detail.

### Convolution

For each bin, convolve with neighbors within radius:

```
filtered_color[u, v] = Σ_{neighbors} kernel(dist) · histogram[neighbor].color / count
```

Common kernels:
- **Gaussian** — e^(-dist² / (2σ²))
- **Box** — uniform within radius

The `estimator_sharpness` parameter controls kernel falloff.

## Log-Density Display

### Alpha Channel

The alpha (opacity) channel is computed as log-density:

```
alpha = log(1 + count) · vibrancy
```

Where:
- `count` is the bin count (or filtered density)
- `vibrancy` scales contrast **(preliminary default: 1.0)**

Logarithmic mapping compresses the dynamic range, preventing washout in dense regions while keeping sparse regions visible.

### Gamma Correction

Final pixel values apply gamma correction:

```
pixel_r = (color_r / count)^(1/gamma)
pixel_g = (color_g / count)^(1/gamma)
pixel_b = (color_b / count)^(1/gamma)
```

Where **(preliminary)** gamma = 2.2 (sRGB) or user-specified.

### Tone Mapping

For HDR output, tone mapping compresses highlights:

```
luminance = 0.2126·r + 0.7152·g + 0.0722·b
mapped_luminance = luminance / (1 + luminance)  // Reinhard
scale = mapped_luminance / luminance
pixel = (r·scale, g·scale, b·scale) · alpha
```

## Quality Parameters

| Parameter | Effect | Preliminary Default |
|-----------|--------|---------------------|
| `quality` (samples) | Total iterations per pixel | 100-500 |
| `oversample` | Super-sampling multiplier | 1-3 |
| `filter_radius` | Density estimation base radius | 10-20 |
| `estimator_minimum` | Density floor for adaptive kernel | 1-5 |
| `estimator_sharpness` | Kernel falloff | 0.5-1.0 |
| `vibrancy` | Color saturation | 1.0 |
| `gamma` | Tone curve | 2.2 |
| `gamma_threshold` | Below-threshold gamma adjustment | 0.01 |

## Animation

Animated flames interpolate transform parameters over time:

- **Affine coefficients** — Linear interpolation (lerp)
- **Variation weights** — Lerp with optional renormalization
- **Color indices** — Lerp
- **Camera** — Center (lerp), scale (log-space), rotation (lerp)
- **Opacity/chaos** — Lerp

See [transitions.md](transitions.md) for detailed interpolation and sequencing.

## Algorithm Summary

1. **Setup** — Define N transforms with affine coefficients and variation weights
2. **Iterate** — Run chaos game for millions of iterations
3. **Accumulate** — Build histogram of point visits and color
4. **Filter** — Apply adaptive density estimation
5. **Map** — Log-density alpha, palette lookup, gamma correction
6. **Output** — Final pixel buffer

The algorithm's beauty emerges from simple rules producing infinite complexity—the essence of fractal generation.

## References

- Draves & Reckase, "The Fractal Flame Algorithm" — https://flam3.com/flame_draves.pdf
- Fractal flame — Wikipedia: https://en.wikipedia.org/wiki/Fractal_flame
- Scott Draves, flam3 reference renderer — https://github.com/scottdraves/flam3
- Hutchison, "Fractals and Self-Similarity" (1981)
- Barnsley, *Fractals Everywhere* (1988)

See [metal-pipeline.md](metal-pipeline.md) for the GPU implementation details.
