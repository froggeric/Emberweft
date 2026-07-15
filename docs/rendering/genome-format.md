# Genome Format
*.flam3 XML genome specification*
> **Status:** preliminary — for review · Emberweft

## Overview

The `.flam3` genome format is an XML-based representation of fractal flame parameters. This document specifies the format we parse, describe the canonical Swift data model, and detail parsing/serialization rules.

## Format History

The `.flam3` format originates from the flam3 reference renderer by Scott Draves. It has evolved through multiple editors:

- **Apophysis** — Windows editor, popular in fractal community
- **JWildfire** — Java-based editor with extended features
- **Chaotica** — Commercial renderer with HDR support

Emberweft aims for compatibility with the core `.flam3` subset.

## Root Element: `<flame>`

### Basic Attributes

```xml
<flame
    name="Sheep_001"
    version="3.0"
    size="1920 1080"
    center="0.0 0.0"
    scale="250.0"
    zoom="0.0"
    rotate="0.0"
    oversample="2"
    quality="200"
    filter="15.0"
    filter_shape="gaussian"
    background="0.0 0.0 0.0"
    gamma="2.2"
    gamma_threshold="0.01"
    vibrancy="1.0"
    estimator_radius="15.0"
    estimator_minimum="1.0"
    estimator_sharpness="0.8"
    temporal_samples="1"
    palette="001"
    hue="0.0"
    time="0.0"
>
```

### Attribute Reference

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `name` | string | "" | Human-readable name |
| `version` | string | "3.0" | Format version (we support 2.x and 3.x) |
| `size` | "w h" | "1920 1080" | Output dimensions in pixels |
| `center` | "x y" | "0.0 0.0" | Camera center in world coordinates |
| `scale` | float | 250.0 | Pixels per unit (zoom level) |
| `zoom` | float | 0.0 | Additional zoom factor (log-scale) |
| `rotate` | float | 0.0 | Rotation angle in degrees |
| `oversample` | int | 1 | Supersampling factor (1-3 typical) |
| `quality` | int | 100 | Iterations per pixel (aka samples) |
| `filter` | float | 1.0 | Density estimation radius |
| `filter_shape` | string | "gaussian" | Kernel type: gaussian, box |
| `background` | "r g b" | "0 0 0" | Background color RGB [0,1] |
| `gamma` | float | 2.2 | Gamma correction value |
| `gamma_threshold` | float | 0.01 | Below-threshold gamma adjustment |
| `vibrancy` | float | 1.0 | Color saturation multiplier |
| `estimator_radius` | float | 10.0 | Density estimation base radius |
| `estimator_minimum` | float | 0.5 | Density floor |
| `estimator_sharpness` | float | 0.8 | Kernel falloff |
| `temporal_samples` | int | 1 | Motion blur samples (unused for static) |
| `palette` | string/int | "0" | Palette index or reference |
| `hue` | float | 0.0 | Hue offset for palette [-1,1] |
| `time` | float | 0.0 | Animation time for keyframes |

### Size and Resolution

```
size="1920 1080"     // Width × Height in pixels
```

For animation sequences, size is typically constant across keyframes.

### Camera Parameters

```
center="0.5 -0.3"    // Center (x, y) in world space
scale="300.0"        // Pixels per unit (higher = closer)
zoom="1.5"           // Additional zoom (log scale)
rotate="45.0"        // Rotation in degrees
```

**Coordinate system:** World coordinates (x, y) map to image pixels via:
1. Translate by center
2. Rotate
3. Scale by (scale × zoom)
4. Offset by (width/2, height/2)

## Transform Element: `<xform>`

Each transform (also called "xform") defines one function in the IFS.

### Basic Syntax

```xml
<xform
    weight="1.0"
    color="0.5"
    symmetry="0"
    coefs="0.5 0.0 0.0 0.5 0.0 0.0"
    post="1.0 0.0 0.0 1.0 0.0 0.0"
    chaos="0.5 0.5 1.0"
    opacity="1.0"
    animate="0"
>
    <var name="linear" weight="1.0"/>
    <var name="sinusoidal" weight="0.3"/>
    <var name="spherical" weight="0.2"/>
</xform>
```

### Attribute Reference

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `weight` | float | 1.0 | Selection probability (relative) |
| `color` | float | 0.0 | Color index [0,1] |
| `symmetry` | int | 0 | Symmetry type (advanced, rarely used) |
| `coefs` | "a b c d e f" | "1 0 0 1 0 0" | Affine coefficients |
| `post` | "a b c d e f" | "1 0 0 1 0 0" | Post-affine coefficients |
| `chaos` | "p1 p2 ..." | "1 1 ..." | Chaos probability matrix |
| `opacity` | float | 1.0 | Blend weight (rarely used) |
| `animate` | int | 0 | Enable animation mode (0/1) |

### Affine Coefficients

```
coefs="a b c d e f"
```

Represents the 2×3 affine matrix (matching flam3's `c[3][2]` row-major
layout — `parser.c:974`, applied at `variations.c:2145`):

```
| a  c  e |
| b  d  f |
| 0  0  1 |
```

Mapping:
```
x' = a·x + c·y + e
y' = b·x + d·y + f
```

**Example:**
```
coefs="0.866025 -0.5 0.5 0.866025 0 0"
```
This is a 30° rotation (cos 30° ≈ 0.866, sin 30° = 0.5): a=cos, b=-sin,
c=sin, d=cos.

### Post-Transform

```
post="1.0 0.0 0.0 1.0 0.0 0.0"
```

Same format as `coefs`, applied after variations. Default is identity (no transformation).

### Chaos Matrix

```
chaos="0.8 0.2 1.0"
```

Modifies probability of choosing the next transform based on current transform. For N transforms, provides N×N values in row-major order:

```
chaos="p_00 p_01 ... p_0(N-1) p_10 p_11 ... p_1(N-1) ..."
```

If omitted, defaults to uniform probability (all 1.0).

### Variations: `<var>`

Variation elements specify non-linear functions and their weights:

```xml
<var name="linear" weight="1.0"/>
<var name="sinusoidal" weight="0.5"/>
<var name="spherical" weight="0.3"/>
<var name="swirl" weight="0.2"/>
```

**Common variation names:**

| Name | Description |
|------|-------------|
| `linear` | Identity (required for pure affine) |
| `sinusoidal` | sin(x), sin(y) |
| `spherical` | Divide by r² |
| `swirl` | Rotational distortion |
| `horseshoe` | Horseshoe mapping |
| `polar` | Polar coordinates |
| `heart` | Heart shape |
| `disc` | Disc mapping |
| `spiral` | Spiral distortion |
| `hyperbolic` | Hyperbolic distortion |
| `julia` | Julia variant |
| `bubble` | Bubble distortion |
| `rectangles` | Rectangular grid |
| `eyefish` | Eye-like distortion |

**Extended variations:** We support the flam3 variation set (50+). Unknown variations are flagged with a warning but don't prevent parsing.

## Final Transform: `<finalxform>`

An optional final transform applied to every point, regardless of selection:

```xml
<finalxform
    weight="0.0"
    coefs="0.99 -0.01 0.01 0.99 0.0 0.0"
>
    <var name="julia" weight="0.1"/>
</finalxform>
```

**Rules:**
- `weight` is typically 0 (never selected in chaos game)
- Applies after every iteration
- Useful for global warping effects

## Palette Specification

### Inline Palette

```xml
<palette>
    <color index="0" rgb="FF00FF"/>
    <color index="1" rgb="00FFFF"/>
    <!-- ... up to 256 entries ... -->
    <color index="255" rgb="FFFFFF"/>
</palette>
```

### Palette Reference

```xml
<palette index="5" hue="0.1"/>
```

References a built-in palette (Apophysis numbering 0-100).

### Data Format

RGB values as hexadecimal 0-255:

```
rgb="RRGGBB"  // Red, Green, Blue in hex
```

Example: `rgb="FF0000"` = pure red.

## Animation Keyframes

Animated flames specify multiple `<flame>` elements with increasing `time` attribute:

```xml
<flame time="0.0" ...>
    <xform coefs="1 0 0 1 0 0">...</xform>
</flame>

<flame time="0.5" ...>
    <xform coefs="0.9 0 0 0.9 0 0">...</xform>
</flame>

<flame time="1.0" ...>
    <xform coefs="0.8 0 0 0.8 0 0">...</xform>
</flame>
```

**Interpolation:** Parameters interpolate linearly between keyframes (see [transitions.md](transitions.md)).

## Complete Example

```xml
<?xml version="1.0" encoding="UTF-8"?>
<flames>
    <flame
        name="Simple_Sierpinski"
        version="3.0"
        size="1920 1080"
        center="0.0 0.0"
        scale="250.0"
        oversample="2"
        quality="200"
        filter="10.0"
        gamma="2.2"
        vibrancy="1.0"
    >
        <xform weight="1.0" color="0.0" coefs="0.5 0 0 0.5 0 0">
            <var name="linear" weight="1.0"/>
        </xform>
        <xform weight="1.0" color="0.5" coefs="0.5 0 0 0.5 1 0">
            <var name="linear" weight="1.0"/>
        </xform>
        <xform weight="1.0" color="1.0" coefs="0.5 0 0 0.5 0.5 0.866">
            <var name="linear" weight="1.0"/>
        </xform>
        
        <palette>
            <color index="0" rgb="1E90FF"/>
            <color index="128" rgb="FFD700"/>
            <color index="255" rgb="FF4500"/>
        </palette>
    </flame>
</flames>
```

## Canonical Swift Model

Our Swift representation uses the following structs:

```swift
struct Flame {
    let name: String
    let size: SIMD2<Int>
    let camera: Camera
    let quality: Quality
    let xforms: [Xform]
    let finalXform: Xform?
    let palette: Palette
    let time: Double  // For animation keyframes
}

struct Xform {
    let affine: AffineTransform  // (a,b,c,d,e,f)
    let postAffine: AffineTransform
    let weight: Float
    let color: Float  // [0,1]
    let variations: [Variation]
    let chaos: [Float]?
    let opacity: Float
}

struct Variation {
    let name: String
    let weight: Float
}

struct Palette {
    let colors: [SIMD3<Float>]  // 256 entries, RGB [0,1]
}

struct Camera {
    let center: SIMD2<Float>
    let scale: Float
    let zoom: Float
    let rotation: Float  // Degrees
}

struct Quality {
    let oversample: Int
    let samplesPerPass: Int
    let filterRadius: Float
    let filterShape: FilterShape
    let gamma: Float
    let vibrancy: Float
    let estimatorRadius: Float
    let estimatorMinimum: Float
    let estimatorSharpness: Float
}
```

## Parsing Rules

### Defaults

When attributes are missing:

| Attribute | Default |
|-----------|---------|
| `size` | "1920 1080" |
| `center` | "0.0 0.0" |
| `scale` | 250.0 |
| `oversample` | 1 |
| `quality` | 100 |
| `gamma` | 2.2 |
| `vibrancy` | 1.0 |
| `filter` | 1.0 |
| `xform.weight` | 1.0 |
| `xform.color` | 0.0 |

### Validation

**Error conditions:**
- Malformed XML (parser error)
- Invalid coefficient count (not 6 values)
- Out-of-range color index (< 0 or > 1)
- Zero or negative scale
- NaN values in coefficients

**Warning conditions:**
- Unknown variation name (skip, log warning)
- Deprecated attributes (ignore, log info)
- Missing chaos matrix (use uniform)
- Non-uniform size across animation keyframes

### Compatibility

**Supported:**
- flam3 2.x and 3.x formats
- Apophysis exports (with caveats for 3D extensions)
- JWildfire basic genomes
- Chaotica .flam3 (subset)

**Unsupported (flagged as warnings):**
- 3D transforms (z-coordinates)
- Channel-specific variations
- Custom variation plugins
- Binary-encoded genomes

## Serialization

When writing genomes:

1. Use version="3.0" in root element
2. Include all attributes with current values
3. Preserve original variation names
4. Normalize coefficient floats to 6 decimal places
5. Include standard XML declaration

**Example output:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<flame name="Exported_Sheep" version="3.0" size="1920 1080" ...>
    <!-- xforms with current values -->
</flame>
```

## Future Extensions

Potential additions:
- `smooth` attribute for interpolation mode (see [transitions.md](transitions.md))
- `links` element for transform symmetry groups
- `image` palette for custom image-based coloring
- Metadata fields (author, date, tags)

## References

- flam3 XML format specification — https://github.com/scottdraves/flam3
- Apophysis format guide — http://apophysis.sourceforge.io/
- [flame-algorithm.md](flame-algorithm.md) — Algorithm description
- [transitions.md](transitions.md) — Animation interpolation
