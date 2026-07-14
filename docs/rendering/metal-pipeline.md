# Metal Pipeline
*GPU compute implementation and kernel architecture*
> **Status:** preliminary — for review · Emberweft

## Overview

The Metal pipeline implements the fractal flame algorithm as a three-stage compute shader architecture on Apple Silicon GPU. This document details the compute kernels, buffer layouts, and Metal-specific optimizations for realtime rendering.

## Pipeline Architecture

```
Input Genome (Swift structs)
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│  Stage 1: Chaos Game / Histogram Accumulation               │
│  (Compute: ChaosGameHistogramKernel)                         │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
Histogram Buffer (count + RGB per bin)
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│  Stage 2: Density Estimation Filter                         │
│  (Compute: DensityEstimationKernel)                         │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
Filtered Histogram Buffer
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│  Stage 3: Palette + Tone Map → Output Texture              │
│  (Compute: PaletteToneMapKernel)                            │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
MTLTexture (RGBA16_half, output frame)
```

## Stage 1: Chaos Game / Histogram Accumulation

### Kernel Overview

The chaos game kernel iterates the IFS and accumulates samples into a spatial histogram. This is the computationally expensive stage—millions of iterations per frame.

```metal
kernel void chaosGameHistogramKernel(
    constant Transform *transforms [[buffer(0)]],
    constant float &probabilities [[buffer(1)]],
    device AtomicBin *histogram [[buffer(2)]],
    constant uint2 &gridSize [[buffer(3)]],
    constant CameraParams &camera [[buffer(4)]],
    constant uint &iterationsPerThread [[buffer(5)]],
    uint2 tid [[thread_position_in_grid]]
);
```

### Per-Thread Execution

Each thread independently runs the chaos game:

```metal
// Initialize random position (skip fuse iterations)
float2 pos = initRandomPosition(tid);
for (int fuse = 0; fuse < FUSE; fuse++) {
    int idx = chooseTransform(probabilities, randState);
    pos = applyTransform(transforms[idx], pos);
}

// Main iteration loop
for (uint iter = 0; iter < iterationsPerThread; iter++) {
    // Choose transform by probability
    int idx = chooseTransform(probabilities, randState);
    
    // Apply transform with variations
    pos = applyTransform(transforms[idx], pos);
    
    // Map to histogram coordinates
    float2 gridPos = worldToGrid(pos, camera, gridSize);
    
    // Convert to integer bin index
    int2 bin = int2(floor(gridPos));
    
    // Check bounds
    if (bin.x >= 0 && bin.x < gridSize.x && bin.y >= 0 && bin.y < gridSize.y) {
        uint index = bin.y * gridSize.x + bin.x;
        
        // Accumulate color
        float3 color = interpolatePalette(runningColor);
        
        // Atomic add to histogram
        atomic_fetch_add_explicit(&histogram[index].count, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&histogram[index].colorR, color.r, memory_order_relaxed);
        atomic_fetch_add_explicit(&histogram[index].colorG, color.g, memory_order_relaxed);
        atomic_fetch_add_explicit(&histogram[index].colorB, color.b, memory_order_relaxed);
    }
}
```

### Histogram Buffer Layout

```metal
struct AtomicBin {
    atomic_uint count;
    atomic_uint colorR;  // Fixed-point or half-float encoded
    atomic_uint colorG;
    atomic_uint colorB;
};
```

**Alternative: Privatized accumulation** (reduces atomic contention):
```metal
threadgroup Bin localHistogram[LOCAL_SIZE];
// ... accumulate locally ...
// ... merge to global via atomics at end ...
```

**Grid resolution:**
- **(preliminary)** Default: 2× output resolution (supersampled)
- 1080p output → 3840×2160 histogram grid
- Higher grid = better quality but more memory

### Variation Functions in MSL

Variations are implemented as inline Metal functions:

```metal
// Example: linear variation
static inline float2 v_linear(float2 p) {
    return p;
}

// Example: sinusoidal variation
static inline float2 v_sinusoidal(float2 p) {
    return float2(sin(p.x), sin(p.y));
}

// Example: spherical variation
static inline float2 v_spherical(float2 p) {
    float r2 = p.x * p.x + p.y * p.y + 1e-10;  // Avoid div/0
    return p / r2;
}

// Example: swirl variation
static inline float2 v_swirl(float2 p) {
    float r2 = p.x * p.x + p.y * p.y;
    float sinR2 = sin(r2);
    float cosR2 = cos(r2);
    return float2(
        p.x * sinR2 - p.y * cosR2,
        p.x * cosR2 + p.y * sinR2
    );
}
```

### Transform Application

```metal
float2 applyTransform(Transform t, float2 pos) {
    // Pre-affine
    float2 p = t.preAffine * float3(pos, 1.0);
    
    // Variations
    float2 result = float2(0.0);
    for (int i = 0; i < NUM_VARIATIONS; i++) {
        result += t.variationWeights[i] * variationFunctions[i](p);
    }
    
    // Post-affine
    return t.postAffine * float3(result, 1.0);
}
```

### Random Number Generation

GPU-friendly RNG using PCG or Wang hash:

```metal
// Wang hash (fast, sufficient for visual randomness)
static inline uint wangHash(uint seed) {
    seed = (seed ^ 61) ^ (seed >> 16);
    seed *= 9;
    seed = seed ^ (seed >> 4);
    seed *= 0x27d4eb2d;
    seed = seed ^ (seed >> 15);
    return seed;
}

// PCG (better statistical properties)
static inline uint pcgHash(uint seed) {
    uint state = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28) + 4)) ^ state) * 277803737u;
    return (word >> 22) ^ word;
}

// Float in [0, 1)
static inline float randFloat(uint &state) {
    state = pcgHash(state);
    return float(state >> 8) * (1.0 / 16777216.0);  // 2^-24
}
```

**Determinism:** Use fixed seeds for reproducible renders (same genome → same output).

### Quality Control

**Iteration budget** is the primary quality knob:

| Quality Level | Iterations per Pixel | Output |
|---------------|---------------------|--------|
| Low (preview) | 50-100 | Rough, fast |
| Medium (default) | 100-200 | Good balance **(preliminary)** |
| High | 500-1000 | Sharp, detailed |
| Ultra | 2000+ | Near-perfect |

Formula: `total_iterations = threads × iterationsPerThread`

## Stage 2: Density Estimation Filter

### Kernel Overview

```metal
kernel void densityEstimationKernel(
    device AtomicBin *input [[buffer(0)]],
    device Bin *output [[buffer(1)]],
    constant uint2 &gridSize [[buffer(2)]],
    constant FilterParams &params [[buffer(3)]],
    uint2 tid [[thread_position_in_grid]]
);
```

### Adaptive Radius Computation

```metal
float adaptiveRadius(uint count, FilterParams params) {
    float density = float(count);
    float radius = params.estimatorRadius *
                  sqrt(params.estimatorMinimum / (density + params.estimatorMinimum));
    return max(radius, 1.0);  // Minimum 1 pixel
}
```

### Convolution

For each bin, gather neighbors within adaptive radius and apply kernel:

```metal
float3 sumColor = float3(0.0);
float sumWeight = 0.0;

float radius = adaptiveRadius(input[index].count, params);
int r = int(ceil(radius));

for (int dy = -r; dy <= r; dy++) {
    for (int dx = -r; dx <= r; dx++) {
        int2 neighbor = tid + int2(dx, dy);
        if (neighbor.x >= 0 && neighbor.x < gridSize.x &&
            neighbor.y >= 0 && neighbor.y < gridSize.y) {
            
            uint nidx = neighbor.y * gridSize.x + neighbor.x;
            float dist = sqrt(float(dx*dx + dy*dy));
            
            if (dist <= radius) {
                // Gaussian kernel
                float weight = exp(-(dist * dist) / (2.0 * radius * radius));
                uint count = input[nidx].count;
                if (count > 0) {
                    sumColor += float3(
                        float(input[nidx].colorR),
                        float(input[nidx].colorG),
                        float(input[nidx].colorB)
                    ) * weight;
                    sumWeight += weight;
                }
            }
        }
    }
}

output[index].color = sumColor / max(sumWeight, 1.0);
output[index].count = input[index].count;  // Preserve for alpha
```

### Filter Parameters

| Parameter | Preliminary Default | Effect |
|-----------|---------------------|--------|
| `estimator_radius` | 15.0 pixels | Base filter radius |
| `estimator_minimum` | 1.0 | Density floor |
| `estimator_sharpness` | 0.8 | Kernel falloff |

## Stage 3: Palette + Tone Mapping

### Kernel Overview

```metal
kernel void paletteToneMapKernel(
    device Bin *histogram [[buffer(0)]],
    texture2d<float, access::write> output [[texture(0)]],
    constant Palette &palette [[buffer(1)]],
    constant ToneMapParams &params [[buffer(2)]],
    uint2 tid [[thread_position_in_grid]]
);
```

### Log-Density Alpha

```metal
uint count = histogram[index].count;
float alpha = log(1.0 + float(count)) * params.vibrancy;
```

### Palette Lookup

Palette stored as 1D texture (256 entries **(preliminary)**):

```metal
float3 paletteLookup(float t) {
    // t ∈ [0, 1], map to palette texel
    float texel = clamp(t, 0.0, 1.0) * 255.0;
    uint idx0 = uint(floor(texel));
    uint idx1 = min(idx0 + 1, 255);
    float frac = texel - float(idx0);
    
    float3 c0 = palette.colors[idx0];
    float3 c1 = palette.colors[idx1];
    
    return mix(c0, c1, frac);  // Linear interpolate
}
```

### Gamma Correction

```metal
float3 applyGamma(float3 color, float gamma) {
    float3 gammaInv = float3(1.0 / gamma);
    return pow(color, gammaInv);
}
```

### Tone Mapping (HDR)

```metal
float3 toneMapReinhard(float3 color) {
    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    float mappedLum = luminance / (1.0 + luminance);
    float scale = mappedLum / max(luminance, 1e-10);
    return color * scale;
}
```

### Final Output

```metal
Bin bin = histogram[index];

// Normalize color
float3 color = bin.color / max(float(bin.count), 1.0);

// Apply gamma
color = applyGamma(color, params.gamma);

// Tone map (if HDR)
color = toneMapReinhard(color);

// Apply log-density alpha
float alpha = log(1.0 + float(bin.count)) * params.vibrancy;

// Output (premultiplied alpha)
float4 finalColor = float4(color * alpha, alpha);

output.write(finalColor, tid);
```

### Output Format

**Recommended: `MTLPixelFormatRGBA16Half`**
- 16-bit half-float per channel
- HDR-capable
- Good quality/performance balance

Alternative: `RGBA8Unorm_sRGB` for gamma-corrected 8-bit output.

## Metal 4 Features

### Argument Buffers

```metal
struct ArgumentBuffer {
    constant Transform *transforms;
    constant float *probabilities;
    device AtomicBin *histogram;
    constant Palette *palette;
    // ... other resources ...
};
```

Encapsulates all resources in a single buffer for efficient binding.

### Untracked Resources

For frequently updated buffers (per-frame uniforms):

```metal
[[address(1)]] device UniformParams &params [[buffer(0)]];
```

Marked as untracked to avoid Metal API overhead for small updates.

### Function Constants

Specialize variation selection at pipeline creation:

```metal
template <typename V>
struct VariationSet {
    static inline float2 apply(float2 p);
};

// Instantiate specific pipeline per variation combination
```

Alternative: Function pointers with dynamic dispatch (slower but more flexible).

### Half Precision

Use `half` and `half2` for compute-intensive paths:

```metal
half2 pos = initRandomHalf2(tid);
// ... compute with half precision ...
```

Reduces memory bandwidth and register pressure.

## Performance Budget

See [performance.md](../engineering/performance.md) for detailed targets:

**Target: 30-60 FPS at 1080p (1920×1080)**
- Stage 1 (chaos game): ~70% of frame time
- Stage 2 (filter): ~20% of frame time
- Stage 3 (palette/tone): ~10% of frame time

**Quality/Performance Trade-offs:**

| Setting | Performance Impact | Visual Impact |
|---------|-------------------|---------------|
| Histogram grid size | O(n²) memory, O(n²) compute | Significant |
| Iterations | Linear in compute | Linear in quality |
| Filter radius | O(r²) per pixel | Moderate |
| Supersampling | O(4×) memory/compute | High |

## Optimization Strategies

### Thread Group Sizing

```metal
// Typical for Apple Silicon
constant uint16_t threadgroupWidth = 32;
constant uint16_t threadgroupHeight = 32;  // Or 16 for higher register pressure
```

### Memory Coalescing

- Ensure histogram accesses are coalesced (thread IDs map linearly to memory)
- Use `threadgroup` memory for privatized histograms
- Minimize atomic contention via spatial hashing

### SIMD Coherency

- Branch divergence in variation selection hurts SIMT performance
- Consider sorting threads by most-used transform
- Use function constants to compile-out unused variations

### Async Compute

Overlap stages with Metal 4 async compute:

```objective-c
[id<MTLCommandBuffer] buffer = queue.commandBuffer;
// Encode stage 1
[buffer addCompletedHandler:^(id<MTLCommandBuffer> buf) {
    // Stage 2 depends on stage 1 completion
}];
```

## Debugging and Validation

### Reference Renders

Generate test frames with known seeds and compare to CPU reference (flam3).

### Visualization Modes

- **Histogram view** — Visualize raw counts
- **Density view** — Show adaptive kernel radii
- **Variation debug** — Color by transform index
- **Heat map** — Show iteration hotspots

## Future GPU Enhancements

- **Mesh shaders** — For geometry-based flame visualization
- **Ray tracing** — For 3D flame extensions
- **Neural upsampling** — ML-based super-resolution
- **Variable rate shading** — Reduce compute in peripheral regions

## References

- [Metal Shading Language Guide](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
- [Metal Best Practices Guide](https://developer.apple.com/metal/Metal-Best-Practices-Guide.pdf)
- [flame-algorithm.md](flame-algorithm.md) — Algorithm description
- [performance.md](../engineering/performance.md) — Performance targets
