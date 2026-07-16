#include <metal_stdlib>
using namespace metal;

// File-scope `constant uint` globals are NOT guaranteed usable as array-size
// constant expressions across MSL revisions; `#define` is universally accepted.
#define ISAAC_RANDSIZL_MS  4
#define ISAAC_RANDSIZ_MS   (1u << ISAAC_RANDSIZL_MS)   // 16
#define ISAAC_RANDSIZ_M1   (ISAAC_RANDSIZ_MS - 1u)

// Faithful port of flam3's ISAAC (isaac.c). State is held in `ulong` to match
// `unsigned long int` (8 bytes) on macOS LP64; the mix() macro runs WITHOUT
// 32-bit masking (load-bearing), and rngstep masks every stored value to 32
// bits exactly as the C does. Verified byte-equal to FlameKit.ISAAC.
struct IsaacState {
    ulong randcnt;                 // countdown into current results batch
    ulong randrsl[ISAAC_RANDSIZ_MS];
    ulong mm[ISAAC_RANDSIZ_MS];
    ulong aa, bb, cc;
};

static inline void isaac_mix(thread ulong& a, thread ulong& b, thread ulong& c,
                             thread ulong& d, thread ulong& e, thread ulong& f,
                             thread ulong& g, thread ulong& h) {
    a ^= (b << 11); d += a; b += c;
    b ^= (c >> 2);  e += b; c += d;
    c ^= (d << 8);  f += c; d += e;
    d ^= (e >> 16); g += d; e += f;
    e ^= (f << 10); h += e; f += g;
    f ^= (g >> 4);  a += f; g += h;
    g ^= (h << 8);  b += g; h += a;
    h ^= (a >> 9);  c += h; a += b;
}

static inline void isaac_rngstep(ulong mixExpr, thread ulong& a, thread ulong& b,
                                 thread ulong* mm, thread ulong* r,
                                 thread uint& m, thread uint& m2) {
    ulong x = mm[m];
    a = ((a ^ mixExpr) + mm[m2]) & 0xffffffffull;
    m2 += 1;
    ulong y = (mm[uint((x >> 2) & ulong(ISAAC_RANDSIZ_M1))] + a + b) & 0xffffffffull;
    mm[m] = y;
    m += 1;
    ulong idx = ((y >> ulong(ISAAC_RANDSIZL_MS)) >> 2) & ulong(ISAAC_RANDSIZ_M1);
    b = (mm[uint(idx)] + x) & 0xffffffffull;
    r[m - 1u] = b;
}

static inline void isaac_generate(thread IsaacState& s) {
    s.cc += 1;
    ulong a = s.aa;
    ulong b = (s.bb + s.cc) & 0xffffffffull;
    uint m = 0;
    uint m2 = ISAAC_RANDSIZ_MS / 2;
    while (m < ISAAC_RANDSIZ_MS / 2) {
        isaac_rngstep(a << 13, a, b, s.mm, s.randrsl, m, m2);
        isaac_rngstep(a >> 6,  a, b, s.mm, s.randrsl, m, m2);
        isaac_rngstep(a << 2,  a, b, s.mm, s.randrsl, m, m2);
        isaac_rngstep(a >> 16, a, b, s.mm, s.randrsl, m, m2);
    }
    m2 = 0;
    while (m2 < ISAAC_RANDSIZ_MS / 2) {
        isaac_rngstep(a << 13, a, b, s.mm, s.randrsl, m, m2);
        isaac_rngstep(a >> 6,  a, b, s.mm, s.randrsl, m, m2);
        isaac_rngstep(a << 2,  a, b, s.mm, s.randrsl, m, m2);
        isaac_rngstep(a >> 16, a, b, s.mm, s.randrsl, m, m2);
    }
    s.bb = b;
    s.aa = a;
}

// Seed from a 16-word randrsl buffer, mirroring flam3's irandinit(ctx, 1).
// `seed16` is `constant` to match the kernel's buffer(0) address space; the
// values are copied into thread-local state before any mutation.
static inline void isaac_init(thread IsaacState& s, constant const ulong* seed16) {
    for (uint i = 0; i < ISAAC_RANDSIZ_MS; i++) { s.mm[i] = 0; s.randrsl[i] = seed16[i] & 0xffffffffull; }
    s.aa = 0; s.bb = 0; s.cc = 0;
    ulong a = 0x9e3779b9, b = 0x9e3779b9, c = 0x9e3779b9, d = 0x9e3779b9;
    ulong e = 0x9e3779b9, f = 0x9e3779b9, g = 0x9e3779b9, h = 0x9e3779b9;
    for (uint i = 0; i < 4; i++) isaac_mix(a, b, c, d, e, f, g, h);
    // Pass 1: fold randrsl into mm.
    for (uint i = 0; i < ISAAC_RANDSIZ_MS; i += 8) {
        a += s.randrsl[i]; b += s.randrsl[i+1]; c += s.randrsl[i+2]; d += s.randrsl[i+3];
        e += s.randrsl[i+4]; f += s.randrsl[i+5]; g += s.randrsl[i+6]; h += s.randrsl[i+7];
        isaac_mix(a, b, c, d, e, f, g, h);
        s.mm[i] = a; s.mm[i+1] = b; s.mm[i+2] = c; s.mm[i+3] = d;
        s.mm[i+4] = e; s.mm[i+5] = f; s.mm[i+6] = g; s.mm[i+7] = h;
    }
    // Pass 2.
    for (uint i = 0; i < ISAAC_RANDSIZ_MS; i += 8) {
        a += s.mm[i]; b += s.mm[i+1]; c += s.mm[i+2]; d += s.mm[i+3];
        e += s.mm[i+4]; f += s.mm[i+5]; g += s.mm[i+6]; h += s.mm[i+7];
        isaac_mix(a, b, c, d, e, f, g, h);
        s.mm[i] = a; s.mm[i+1] = b; s.mm[i+2] = c; s.mm[i+3] = d;
        s.mm[i+4] = e; s.mm[i+5] = f; s.mm[i+6] = g; s.mm[i+7] = h;
    }
    isaac_generate(s);
    s.randcnt = ulong(ISAAC_RANDSIZ_MS);   // consume from the top
}

// irand(): consume next 32-bit word. Matches FlameKit ISAAC.next() exactly.
static inline uint isaac_next(thread IsaacState& s) {
    if (s.randcnt == 0) {
        isaac_generate(s);
        s.randcnt = ulong(ISAAC_RANDSIZ_MS - 1);
    } else {
        s.randcnt -= 1;
    }
    return uint(s.randrsl[uint(s.randcnt)]);   // already masked to 32 bits
}

// Test kernel: seed from seed16[0..15], emit `count` words into out[0..count].
kernel void isaac_check(constant const ulong* seed16 [[buffer(0)]],
                        device uint* out [[buffer(1)]],
                        constant const uint& count [[buffer(2)]],
                        uint gid [[thread_position_in_grid]]) {
    if (gid != 0) return;
    IsaacState s;
    isaac_init(s, seed16);
    for (uint i = 0; i < count; i++) { out[i] = isaac_next(s); }
}

kernel void noop_kernel(device uint* out [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    if (gid == 0) { out[0] = 0x4d657461; }  // "Meta"
}

// ---- Device mirrors of Swift GPUXform / GPUFrameParams (field order identical) ----
//
// These cross the Swift→MSL boundary as raw bytes, so field order, types, and
// sizes MUST match the Swift structs in MetalHost.swift exactly. Both sides are
// all-`float`/`uint` (4-byte aligned); GPUXform is 6+6+3+19 = 34 floats = 136 B.

struct GPUXform {
    float a, b, c, d, e, f;
    float pa, pb, pc, pd, pe, pf;
    float color, colorSpeed, opacity;
    float varWeights[19];
};

struct GPUFrameParams {
    uint gridWidth, gridHeight, gutter;
    float oversample, cosR, sinR, pixelsPerUnit, centerX, centerY;
    uint iterationsPerThread, remainder, threadCount, fuse, cmapSize, cmapSizeM1;
    float colorScale;
    uint hasFinal;
};

// Palette: 256 pre-scaled RGB entries (dmap), passed as a flat float3 array.

// MARK: - Stage-1 chaos-game kernel
//
// Faithful GPU mirror of `FlameReference.ChaosGame.iterate`. The 19 variation
// formulas are line-for-line ports of `FlameKit.Variations` (which itself ports
// flam3 variations.c). The affine convention, `precalc_atan = atan2(x,y)` (x
// first — flam3's swapped angle), EPS, badvalue threshold, palette interp,
// camera projection, final-xform SEPARATE binning point, and badvalue retry
// (5-consecutive limit, `continue` without advancing `j`) all match the CPU
// oracle. Float (not Double) math — accepted by the statistical-parity model.

constant float EPS_MS  = 1e-10f;
constant float BAD_MS  = 1e10f;
constant uint CHAOS_GRAIN_M1 = 16383u;

struct AtomicBin {
    atomic_uint count;
    atomic_uint r, g, b, a;
};

static inline bool badvalue_ms(float x) { return (x != x) || (x > BAD_MS) || (x < -BAD_MS); }

static inline float2 apply_affine(GPUXform x, float2 p) {
    return float2(x.a*p.x + x.c*p.y + x.e, x.b*p.x + x.d*p.y + x.f);
}
static inline float2 apply_post(GPUXform x, float2 p) {
    return float2(x.pa*p.x + x.pc*p.y + x.pe, x.pb*p.x + x.pd*p.y + x.pf);
}
static inline float blend_color(GPUXform x, float ct) {
    return (1.0f - x.colorSpeed) * ct + x.colorSpeed * x.color;
}

// 19 variation terms (canonical slot order). Each returns the term that CPU
// `Variations.evaluate` would add to f.p0/p1, weight folded at flam3's exact
// position. Float (not Double) — accepted by the statistical-parity model.
static inline float2 v_bent(float2 p, float w) {
    return float2(w * (p.x < 0 ? 2.0f*p.x : p.x), w * (p.y < 0 ? 0.5f*p.y : p.y));
}
static inline float2 v_cosine(float2 p, float w) {
    return float2(w * cos(p.x * M_PI_F) * cosh(p.y), w * (-sin(p.x * M_PI_F)) * sinh(p.y));
}
static inline float2 v_cylinder(float2 p, float w) { return float2(w * sin(p.x), w * p.y); }
static inline float2 v_diamond(float2 p, float w) {
    float r = sqrt(p.x*p.x + p.y*p.y); float a = atan2(p.x, p.y);
    return float2(w * sin(a) * cos(r), w * cos(a) * sin(r));
}
static inline float2 v_disc(float2 p, float w) {
    float a = atan2(p.x, p.y) / M_PI_F; float r = M_PI_F * sqrt(p.x*p.x + p.y*p.y);
    return float2(w * sin(r) * a, w * cos(r) * a);
}
static inline float2 v_ex(float2 p, float w) {
    float a = atan2(p.x, p.y); float r = sqrt(p.x*p.x + p.y*p.y);
    float n0 = sin(a + r); float n1 = cos(a - r);
    float m0 = n0*n0*n0 * r; float m1 = n1*n1*n1 * r;
    return float2(w * (m0 + m1), w * (m0 - m1));
}
static inline float2 v_exponential(float2 p, float w) {
    float e = exp(p.x - 1.0f);
    return float2(w * e * cos(M_PI_F * p.y), w * e * sin(M_PI_F * p.y));
}
static inline float2 v_fisheye(float2 p, float w) {
    float r = 2.0f / (sqrt(p.x*p.x + p.y*p.y) + 1.0f);
    return float2(w * r * p.y, w * r * p.x);
}
static inline float2 v_handkerchief(float2 p, float w) {
    float a = atan2(p.x, p.y); float r = sqrt(p.x*p.x + p.y*p.y);
    return float2(w * r * sin(a + r), w * r * cos(a - r));
}
static inline float2 v_heart(float2 p, float w) {
    float ps = sqrt(p.x*p.x + p.y*p.y); float a = ps * atan2(p.x, p.y); float r = w * ps;
    return float2(r * sin(a), (-r) * cos(a));
}
static inline float2 v_horseshoe(float2 p, float w) {
    float r = w / (sqrt(p.x*p.x + p.y*p.y) + EPS_MS);
    return float2((p.x - p.y) * (p.x + p.y) * r, 2.0f * p.x * p.y * r);
}
static inline float2 v_hyperbolic(float2 p, float w) {
    float r = sqrt(p.x*p.x + p.y*p.y) + EPS_MS; float a = atan2(p.x, p.y);
    return float2(w * sin(a) / r, w * cos(a) * r);
}
// julia — consumes one ISAAC word (lowest bit), exactly like CPU `rng.bit()`.
static inline float2 v_julia(float2 p, float w, thread IsaacState& rng) {
    float sumsq = p.x*p.x + p.y*p.y;
    float ps = sqrt(sumsq);
    float a = 0.5f * atan2(p.x, p.y);
    float r = w * sqrt(ps);
    if ((isaac_next(rng) & 1u) != 0u) { a += M_PI_F; }
    return float2(r * cos(a), r * sin(a));
}
static inline float2 v_linear(float2 p, float w) { return float2(w * p.x, w * p.y); }
static inline float2 v_polar(float2 p, float w) {
    float nx = atan2(p.x, p.y) / M_PI_F; float ny = sqrt(p.x*p.x + p.y*p.y) - 1.0f;
    return float2(w * nx, w * ny);
}
static inline float2 v_sinusoidal(float2 p, float w) { return float2(w * sin(p.x), w * sin(p.y)); }
static inline float2 v_spherical(float2 p, float w) {
    float r2 = w / (p.x*p.x + p.y*p.y + EPS_MS); return float2(r2 * p.x, r2 * p.y);
}
static inline float2 v_spiral(float2 p, float w) {
    float r = sqrt(p.x*p.x + p.y*p.y) + EPS_MS; float r1 = w / r; float a = atan2(p.x, p.y);
    return float2(r1 * (cos(a) + sin(r)), r1 * (sin(a) - cos(r)));
}
static inline float2 v_swirl(float2 p, float w) {
    float r2 = p.x*p.x + p.y*p.y; float c1 = sin(r2); float c2 = cos(r2);
    return float2(w * (c1*p.x - c2*p.y), w * (c2*p.x + c1*p.y));
}

// Sum the 19 canonical slots. Only `julia` consumes the RNG.
// CRITICAL: every slot MUST be guarded by `w[i] != 0` to match CPU
// (`Variations.evaluate` skips weight==0). Without the guard, a weight-0
// variation whose internals overflow to Inf (cosh/sinh in `cosine` for
// |p.y|>710, exp in `exponential` for |p.x|>710) yields `0.0f * Inf == NaN`,
// which contaminates `acc`, trips `badvalue_ms`, and diverges both the
// trajectory and the RNG stream from the CPU.
static inline float2 apply_xform_body(GPUXform x, float2 p, thread IsaacState& rng) {
    float2 pre = apply_affine(x, p);
    float2 acc = float2(0.0f);
    float w[19];
    for (int i = 0; i < 19; i++) w[i] = x.varWeights[i];
    if (w[0]  != 0.0f) acc += v_bent(pre, w[0]);
    if (w[1]  != 0.0f) acc += v_cosine(pre, w[1]);
    if (w[2]  != 0.0f) acc += v_cylinder(pre, w[2]);
    if (w[3]  != 0.0f) acc += v_diamond(pre, w[3]);
    if (w[4]  != 0.0f) acc += v_disc(pre, w[4]);
    if (w[5]  != 0.0f) acc += v_ex(pre, w[5]);
    if (w[6]  != 0.0f) acc += v_exponential(pre, w[6]);
    if (w[7]  != 0.0f) acc += v_fisheye(pre, w[7]);
    if (w[8]  != 0.0f) acc += v_handkerchief(pre, w[8]);
    if (w[9]  != 0.0f) acc += v_heart(pre, w[9]);
    if (w[10] != 0.0f) acc += v_horseshoe(pre, w[10]);
    if (w[11] != 0.0f) acc += v_hyperbolic(pre, w[11]);
    if (w[12] != 0.0f) acc += v_julia(pre, w[12], rng);
    if (w[13] != 0.0f) acc += v_linear(pre, w[13]);
    if (w[14] != 0.0f) acc += v_polar(pre, w[14]);
    if (w[15] != 0.0f) acc += v_sinusoidal(pre, w[15]);
    if (w[16] != 0.0f) acc += v_spherical(pre, w[16]);
    if (w[17] != 0.0f) acc += v_spiral(pre, w[17]);
    if (w[18] != 0.0f) acc += v_swirl(pre, w[18]);
    return apply_post(x, acc);
}

static inline float isaac_01(thread IsaacState& s) {
    return float(isaac_next(s) & 0x0fffffffu) * (1.0f / float(0x0fffffffu));
}
static inline float isaac_11(thread IsaacState& s) {
    return (float(isaac_next(s) & 0x0fffffffu) - float(0x07ffffffu)) * (1.0f / float(0x07ffffffu));
}

static inline void accumulate(device AtomicBin* hist, int u, int v, GPUFrameParams fp,
                              constant float3* dmap, constant float* dmapAlpha,
                              float binColor) {
    float dblIndex0 = binColor * float(fp.cmapSize);
    int ci0 = int(dblIndex0);
    float frac;
    if (ci0 >= int(fp.cmapSizeM1)) { ci0 = int(fp.cmapSizeM1) - 1; frac = 1.0f; }
    else { frac = dblIndex0 - float(ci0); }
    float m0 = 1.0f - frac;
    float3 interp = dmap[ci0] * m0 + dmap[ci0 + 1] * frac;
    float interpA = dmapAlpha[ci0] * m0 + dmapAlpha[ci0 + 1] * frac;
    float sc = fp.colorScale;
    auto q = [](float v, float s) -> uint { return uint(clamp(v, 0.0f, 255.0f) * s + 0.5f); };
    uint idx = uint(u) + uint(v) * fp.gridWidth;
    atomic_fetch_add_explicit(&hist[idx].count, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[idx].r, q(interp.x, sc), memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[idx].g, q(interp.y, sc), memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[idx].b, q(interp.z, sc), memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[idx].a, q(interpA,  sc), memory_order_relaxed);
}

kernel void chaosGame(device GPUXform* xforms        [[buffer(0)]],
                      device GPUXform* finalXf        [[buffer(1)]],
                      constant uint*   distrib        [[buffer(2)]],
                      constant float3* dmap           [[buffer(3)]],
                      constant float*  dmapAlpha      [[buffer(4)]],
                      constant GPUFrameParams* fp     [[buffer(5)]],
                      constant ulong*  threadSeeds    [[buffer(6)]],
                      device AtomicBin* hist          [[buffer(7)]],
                      uint gid [[thread_position_in_grid]]) {
    if (gid >= fp->threadCount) return;
    IsaacState rng;
    isaac_init(rng, &threadSeeds[ulong(gid) * ISAAC_RANDSIZ_MS]);

    // Sub-batch seed draws (mirror CPU rect.c:393-396): p, colorT, vis(discarded).
    // NOTE: RNG draws are issued via explicit ordered temporaries (NOT as
    // float2-constructor arguments) because C++ function-argument evaluation
    // order is UNSPECIFIED — constructor args could swap the x/y draws and
    // diverge the ISAAC stream from the CPU oracle, which draws p[0] then p[1].
    float px = isaac_11(rng);
    float py = isaac_11(rng);
    float2 p = float2(px, py);
    float colorT = isaac_01(rng);
    (void)isaac_01(rng);

    uint iterThisThread = fp->iterationsPerThread + (gid < fp->remainder ? 1u : 0u);
    uint total = fp->fuse + iterThisThread;
    uint consec = 0;
    bool hasFinal = (fp->hasFinal != 0u);
    GPUXform fin = hasFinal ? finalXf[0] : GPUXform{};

    // CRITICAL: this MUST be a `while` loop with an explicit `j += 1` at the
    // bottom, NOT a C `for`. The CPU oracle uses `while j < total { ...; j += 1 }`
    // where `continue` (badvalue retry) SKIPS `j += 1`, re-running the same slot.
    // A C `for`'s `continue` runs the increment, burning a post-fuse slot on
    // every retry so Metal emits FEWER than `totalSamples` samples and diverges.
    uint j = 0;
    while (j < total) {
        uint xfIdx = distrib[isaac_next(rng) & CHAOS_GRAIN_M1];
        GPUXform xf = xforms[xfIdx];
        float2 q = apply_xform_body(xf, p, rng);
        float qColor = blend_color(xf, colorT);

        if (badvalue_ms(q.x) || badvalue_ms(q.y)) {
            // Init-declarators in a declaration are sequenced left-to-right
            // (C++17 [dcl.decl]); rx draws before ry, matching CPU.
            float rx = isaac_11(rng), ry = isaac_11(rng);
            consec += 1u;
            if (consec < 5u) { p = float2(rx, ry); continue; }   // retry slot; j NOT advanced
            q = float2(rx, ry); consec = 0u;
        } else {
            consec = 0u;
        }

        p = q; colorT = qColor;   // iteration point carries ONLY the main xform

        float2 binP = p; float binColor = colorT;
        if (hasFinal) {
            bool apply;
            if (fin.opacity >= 1.0f) apply = true;
            else if (fin.opacity > 0.0f) apply = (isaac_01(rng) < fin.opacity);
            else apply = false;
            if (apply) { binP = apply_xform_body(fin, p, rng); binColor = blend_color(fin, colorT); }
        }

        if (j >= fp->fuse) {
            if (binP.x == binP.x && binP.y == binP.y) {   // NaN check
                float dx = binP.x - fp->centerX, dy = binP.y - fp->centerY;
                float rxs = dx * fp->cosR - dy * fp->sinR;
                float rys = dx * fp->sinR + dy * fp->cosR;
                float gx = rxs * fp->pixelsPerUnit + float(fp->gridWidth) * 0.5f;
                float gy = rys * fp->pixelsPerUnit + float(fp->gridHeight) * 0.5f;
                int u = int(floor(gx)); int v = int(floor(gy));
                if (u >= 0 && u < int(fp->gridWidth) && v >= 0 && v < int(fp->gridHeight)) {
                    accumulate(hist, u, v, fp[0], dmap, dmapAlpha, binColor);
                }
            }
        }
        j += 1;
    }
}

// MARK: - Stage-2 density-estimation kernel
//
// GPU twin of `FlameReference.DensityEstimation.apply` (the M1 adaptive-kernel
// approximation, NOT true flam3 density estimation). Per-bin adaptive-kernel
// smoothing of the AVERAGE bin color: the kernel shrinks where a bin is dense,
// grows where sparse, and writes the smoothed average back to the SAME bin
// scaled by that bin's (unchanged) count. Energy is NOT convolved into neighbor
// output bins. `radius == 0` is an exact passthrough (guarded on the host too).
//
// Two-buffer form: `inOut` is read, `work` is written — avoids in-kernel
// read-after-write hazards. The host copies `work` out after completion.

struct FloatBin {
    float count, r, g, b, a;
};

kernel void densityEstimation(device FloatBin* inOut [[buffer(0)]],
                              constant const float* params [[buffer(1)]],
                              constant const uint2* dims   [[buffer(2)]],
                              device FloatBin* work        [[buffer(3)]],
                              uint2 tid [[thread_position_in_grid]]) {
    uint gw = dims->x, gh = dims->y;
    if (tid.x >= gw || tid.y >= gh) return;
    uint idx = tid.y * gw + tid.x;
    float radius  = params[0];     // estimator_radius
    float minimum = params[1];     // estimator_minimum
    float curve   = params[2];     // estimator_curve
    if (radius <= 0.0f) { work[idx] = inOut[idx]; return; }   // passthrough

    float cnt = inOut[idx].count;
    if (cnt <= 0.0f) { work[idx] = inOut[idx]; return; }
    int maxR = int(ceil(radius));
    float adapt = radius * pow(minimum / (cnt + minimum), curve);
    float r = clamp(adapt, 0.0f, float(maxR));
    int ri = int(ceil(r));
    float3 colorAvg = float3(inOut[idx].r, inOut[idx].g, inOut[idx].b) / cnt;
    float  alphaAvg = inOut[idx].a / cnt;
    float3 acc = float3(0.0f); float accA = 0.0f; float wsum = 0.0f;
    for (int dy = -ri; dy <= ri; dy++) {
        for (int dx = -ri; dx <= ri; dx++) {
            int nx = int(tid.x) + dx, ny = int(tid.y) + dy;
            if (nx < 0 || nx >= int(gw) || ny < 0 || ny >= int(gh)) continue;
            float dist = sqrt(float(dx*dx + dy*dy));
            float w = max(0.0f, 1.0f - dist / max(r, 1.0f));   // conical kernel
            FloatBin nb = inOut[uint(ny) * gw + uint(nx)];
            bool populated = nb.count > 0.0f;
            float3 localC = populated ? float3(nb.r, nb.g, nb.b) / nb.count : colorAvg;
            float  localA = populated ? nb.a / nb.count : alphaAvg;
            acc += localC * w; accA += localA * w; wsum += w;
        }
    }
    FloatBin out;
    out.count = cnt;
    if (wsum > 0.0f) {
        float3 c = (acc / wsum) * cnt;
        out.r = c.x; out.g = c.y; out.b = c.z;
        out.a = (accA / wsum) * cnt;
    } else {
        out.r = colorAvg.x * cnt; out.g = colorAvg.y * cnt; out.b = colorAvg.z * cnt;
        out.a = alphaAvg * cnt;
    }
    work[idx] = out;
}

// MARK: - Stage-3a display pipeline (log-density + spatial filter + gamma)
//
// Faithful MSL twin of `FlameReference.ToneMapping.render` (which ports flam3
// rect.c + palettes.c). Two kernels: `logDensity` (per grid cell, rect.c:949-973
// de==0 path) and `displayPipeline` (per output pixel, rect.c:1137-1202 gather +
// gamma). DisplayParams lays out as 9 floats + 7 uints = 64 bytes, matching the
// Swift `DisplayPipelineMetal.DisplayParams` mirror exactly (4-byte aligned, no
// padding). The host copies `MemoryLayout<DisplayParams>.size` bytes.

constant float PREFILTER_WHITE_MS = 255.0f;
constant float WHITE_LEVEL_MS     = 255.0f;

struct DisplayParams {
    float k1, k2;
    float gammaInv, linrange, vibrancy;
    float bgR, bgG, bgB;
    float highlightPower;
    uint  gw, gh, width, height, oversample, fw, gutter;
};

// Stage 3 step 1: per grid cell, log-density scale. Reads raw histogram (Float
// bins: count,r,g,b,a in dmap units), writes accumulator (rgb + a).
kernel void logDensity(device FloatBin* raw     [[buffer(0)]],
                       device float*  accumRGB  [[buffer(1)]],
                       device float*  accumA    [[buffer(2)]],
                       constant const DisplayParams* dp [[buffer(3)]],
                       uint2 tid [[thread_position_in_grid]]) {
    if (tid.x >= dp->gw || tid.y >= dp->gh) return;
    uint idx = tid.y * dp->gw + tid.x;
    float c3 = raw[idx].a;                       // rect.c:959 b[0][3]
    if (c3 == 0.0f) {                            // rect.c:960
        accumRGB[idx*3] = 0; accumRGB[idx*3+1] = 0; accumRGB[idx*3+2] = 0;
        accumA[idx] = 0; return;
    }
    float ls = dp->k1 * log(1.0f + c3 * dp->k2) / c3;   // rect.c:963
    accumRGB[idx*3]   = raw[idx].r * ls;
    accumRGB[idx*3+1] = raw[idx].g * ls;
    accumRGB[idx*3+2] = raw[idx].b * ls;
    accumA[idx] = c3 * ls;
}

// palettes.c:274-289
static inline float calc_alpha(float density, float gamma, float linrange) {
    float dnorm = density;
    float funcval = pow(linrange, gamma);
    if (dnorm > 0) {
        if (dnorm < linrange) {
            float frac = dnorm / linrange;
            return (1.0f - frac) * dnorm * (funcval / linrange) + frac * pow(density, gamma);
        }
        return pow(density, gamma);
    }
    return 0;
}

// palettes.c:292-348. M2 only renders at default highlightPower=-1, where the
// saturated-highlight (HSV) branch is unreachable; this keeps the `else`
// (maxa<=255) path, the only one CPU ToneMapping exercises on the goldens.
static inline float3 calc_newrgb(float3 cbuf, float ls, float highpow) {
    if (ls == 0 || (cbuf.x == 0 && cbuf.y == 0 && cbuf.z == 0)) return 0.0f;
    float maxa = -1.0f; float maxc = 0.0f;
    for (int i = 0; i < 3; i++) {
        float a = ls * (cbuf[i] / PREFILTER_WHITE_MS);
        if (a > maxa) { maxa = a; maxc = cbuf[i] / PREFILTER_WHITE_MS; }
    }
    float newls = 255.0f / maxc;
    float adjhlp = -highpow; if (adjhlp > 1) adjhlp = 1; if (maxa <= 255) adjhlp = 1;
    float blend = (1 - adjhlp) * newls + adjhlp * ls;
    return float3(blend * cbuf.x / PREFILTER_WHITE_MS,
                  blend * cbuf.y / PREFILTER_WHITE_MS,
                  blend * cbuf.z / PREFILTER_WHITE_MS);
}

// Stage 3 steps 2+3: per output pixel, spatial-filter gather + gamma + write RGBA8.
kernel void displayPipeline(device const float* accumRGB [[buffer(0)]],
                            device const float* accumA   [[buffer(1)]],
                            constant const float* spatialKernel [[buffer(2)]],
                            constant const DisplayParams* dp [[buffer(3)]],
                            device uchar* rgbaOut [[buffer(4)]],
                            uint2 tid [[thread_position_in_grid]]) {
    if (tid.x >= dp->width || tid.y >= dp->height) return;
    uint ox = tid.x, oy = tid.y;
    // CRITICAL: gather origin is `ox*oversample` with NO gutter added — matches
    // CPU ToneMapping (hardcoded deOffset=0). Adding `+gutter` shifts every tap
    // by `gutter` cells for oversample>1 (oversample=2 → fw=4, gutter=1 → 1-cell
    // shift), breaking the Stage-3a ≥50 dB same-histogram gate. Do NOT add gutter.
    float3 tRGB = 0.0f; float tA = 0.0f;
    for (uint jj = 0; jj < dp->fw; jj++) {
        for (uint ii = 0; ii < dp->fw; ii++) {
            int xx = int(ox * dp->oversample) + int(ii);
            int yy = int(oy * dp->oversample) + int(jj);
            if (xx < 0 || xx >= int(dp->gw) || yy < 0 || yy >= int(dp->gh)) continue;
            float k = spatialKernel[ii + jj * dp->fw];
            uint idx = uint(yy) * dp->gw + uint(xx);
            tRGB += k * float3(accumRGB[idx*3], accumRGB[idx*3+1], accumRGB[idx*3+2]);
            tA   += k * accumA[idx];
        }
    }
    uint base = (oy * dp->width + ox) * 4;
    rgbaOut[base + 3] = 255;                      // opaque output
    if (tA <= 0) {                                // rect.c:1171
        rgbaOut[base] = 0; rgbaOut[base+1] = 0; rgbaOut[base+2] = 0;
        return;
    }
    float tmp = tA / PREFILTER_WHITE_MS;
    float alpha = calc_alpha(tmp, dp->gammaInv, dp->linrange);
    float ls2 = dp->vibrancy * 256.0f * alpha / tmp;     // rect.c:1176
    float3 newrgb = calc_newrgb(tRGB, ls2, dp->highlightPower);
    float3 bg = float3(dp->bgR, dp->bgG, dp->bgB);
    for (int c = 0; c < 3; c++) {
        float a = newrgb[c];
        a += (1.0f - dp->vibrancy) * 256.0f * pow(tRGB[c] / PREFILTER_WHITE_MS, dp->gammaInv);
        a += (1.0f - alpha) * bg[c];
        a = clamp(a, 0.0f, 255.0f);
        rgbaOut[base + c] = uchar(a + 0.5f);
    }
}
