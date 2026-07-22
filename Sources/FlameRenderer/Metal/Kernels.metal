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

// [0,1) and [-1,1) floats from one ISAAC word, matching FlameKit's isaac01/isaac11.
// Defined early so the RNG-consuming variation functions (v_julian, etc.) can see them.
static inline float isaac_01(thread IsaacState& s) {
    return float(isaac_next(s) & 0x0fffffffu) * (1.0f / float(0x0fffffffu));
}
static inline float isaac_11(thread IsaacState& s) {
    return (float(isaac_next(s) & 0x0fffffffu) - float(0x07ffffffu)) * (1.0f / float(0x07ffffffu));
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

// ---- Device mirrors of Swift GPUXform / GPUFrameParams (field order identical) ----
//
// These cross the Swift→MSL boundary as raw bytes (a flat [Float] pack on the
// Swift side), so field order, types, and sizes MUST match the layout constants
// in MetalHost.swift exactly. Both sides are all-`float`/`uint` (4-byte aligned).
// GPUXform is 6+6+3+55+(55*8) = 510 floats = 2040 B. MSL arrays are inline (no
// heap indirection), so varWeights/varParams land contiguously inside the struct.

#define NUM_XFORM_SLOTS_MS 55
#define SLOT_WIDTH_MS      8

struct GPUXform {
    float a, b, c, d, e, f;
    float pa, pb, pc, pd, pe, pf;
    float color, colorSpeed, opacity;
    float varWeights[NUM_XFORM_SLOTS_MS];                       // 55
    float varParams[NUM_XFORM_SLOTS_MS * SLOT_WIDTH_MS];        // 55*8 = 440
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
// Faithful GPU mirror of `FlameReference.ChaosGame.iterate`. The 55 variation
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

// 55 variation terms (canonical slot order). Each returns the term that CPU
// `Variations.evaluate` would add to f.p0/p1, weight folded at flam3's exact
// position. Float (not Double) — accepted by the statistical-parity model.
static inline float2 v_bent(float2 p, float w) {
    return float2(w * (p.x < 0 ? 2.0f*p.x : p.x), w * (p.y < 0 ? 0.5f*p.y : p.y));
}
static inline float2 v_cosine(float2 p, float w) {
    return float2(w * cos(p.x * M_PI_F) * cosh(p.y), w * (-sin(p.x * M_PI_F)) * sinh(p.y));
}
static inline float2 v_cylinder(float2 p, float w) { return float2(w * sin(p.x), w * p.y); }
// var28_bubble (variations.c:671-678): r = w/(0.25*sumsq + 1); (r*p.x, r*p.y).
// Paramless; 0 RNG draws.
static inline float2 v_bubble(float2 p, float w) {
    float r = w / (0.25f * (p.x*p.x + p.y*p.y) + 1.0f);
    return float2(r * p.x, r * p.y);
}
// var27_eyefish (variations.c:659-669): r = (w*2)/(sqrt(sumsq) + 1); (r*p.x, r*p.y).
// Paramless; 0 RNG draws. NOT a fisheye (var16) alias — output is UN-swapped,
// vs fisheye's (r*p.y, r*p.x). Both share the magnitude r = 2w/(|p|+1).
static inline float2 v_eyefish(float2 p, float w) {
    float r = (w * 2.0f) / (sqrt(p.x*p.x + p.y*p.y) + 1.0f);
    return float2(r * p.x, r * p.y);
}
// var15_waves (variations.c:396-413) + waves_precalc (L1969-1975).
//   waves_dx2 = 1/(e²+EPS); waves_dy2 = 1/(f²+EPS);  (e = c[2][0], f = c[2][1])
//   nx = p.x + c*sin(p.y*waves_dx2);   ny = p.y + d*sin(p.x*waves_dy2);
//   (w*nx, w*ny). Paramless; 0 RNG draws. Needs affine c,d,e,f.
static inline float2 v_waves(float2 p, float w, float c, float d, float e, float f) {
    float waves_dx2 = 1.0f / (e*e + EPS_MS);
    float waves_dy2 = 1.0f / (f*f + EPS_MS);
    float nx = p.x + c * sin(p.y * waves_dx2);
    float ny = p.y + d * sin(p.x * waves_dy2);
    return float2(w * nx, w * ny);
}
// var17_popcorn (variations.c:433-450). Paramless; 0 RNG draws. Needs affine e,f.
//   dx = tan(3*ty); dy = tan(3*tx);
//   nx = tx + e*sin(dx); ny = ty + f*sin(dy); (w*nx, w*ny).
static inline float2 v_popcorn(float2 p, float w, float e, float f) {
    float dx = tan(3.0f * p.y);
    float dy = tan(3.0f * p.x);
    float nx = p.x + e * sin(dx);
    float ny = p.y + f * sin(dy);
    return float2(w * nx, w * ny);
}
// var19_power (variations.c:472-487) — precalc sina/cosa/sqrt.
//   sina = tx/sqrt; cosa = ty/sqrt; sqrt = sqrt(tx²+ty²);
//   r = w*pow(sqrt, sina); (r*cosa, r*sina). Paramless; 0 RNG draws.
static inline float2 v_power(float2 p, float w) {
    float ps = sqrt(p.x*p.x + p.y*p.y);
    float sina = p.x / ps;
    float cosa = p.y / ps;
    float r = w * pow(ps, sina);
    return float2(r * cosa, r * sina);
}
// var42_tangent (variations.c:885-898).
//   (w * sin(tx)/cos(ty), w * tan(ty)). Paramless; 0 RNG draws.
static inline float2 v_tangent(float2 p, float w) {
    return float2(w * sin(p.x) / cos(p.y), w * tan(p.y));
}
// var48_cross (variations.c:1033-1052).
//   s = tx² - ty²; r = w*sqrt(1/(s²+EPS)); (tx*r, ty*r). Paramless; 0 RNG draws.
static inline float2 v_cross(float2 p, float w) {
    float s = p.x*p.x - p.y*p.y;
    float r = w * sqrt(1.0f / (s*s + EPS_MS));
    return float2(p.x * r, p.y * r);
}
// var24_pdj (variations.c:579-596). 4 params (pdj_a/b/c/d), all default 0.
//   nx1 = cos(pdj_b*tx); nx2 = sin(pdj_c*tx);
//   ny1 = sin(pdj_a*ty); ny2 = cos(pdj_d*ty);
//   (w*(ny1 - nx1), w*(nx2 - ny2)). Parametric; 0 RNG draws.
// Param order in pr[0..3] = descriptor-declared order: pdj_a, pdj_b, pdj_c, pdj_d.
static inline float2 v_pdj(float2 p, float w, thread const float* pr) {
    float a = pr[0], b = pr[1], c = pr[2], d = pr[3];
    float nx1 = cos(b * p.x);
    float nx2 = sin(c * p.x);
    float ny1 = sin(a * p.y);
    float ny2 = cos(d * p.y);
    return float2(w * (ny1 - nx1), w * (nx2 - ny2));
}
// var74_split (variations.c:1603-1617). 2 params (split_xsize/ysize), default 0.
// p1 branch comes FIRST in C source (mirror structure; p0/p1 accumulate
// independently so order is observationally equivalent). CROSS-COUPLING:
// tx controls p1, ty controls p0.
//   if (cos(tx*split_xsize*π) >= 0) p1 += w*ty  else  p1 -= w*ty;
//   if (cos(ty*split_ysize*π) >= 0) p0 += w*tx  else  p0 -= w*tx;
// Parametric; 0 RNG draws.
// Param order in pr[0..1] = descriptor-declared order: split_xsize, split_ysize.
static inline float2 v_split(float2 p, float w, thread const float* pr) {
    float xsize = pr[0], ysize = pr[1];
    float p0 = 0.0f, p1 = 0.0f;
    if (cos(p.x * xsize * M_PI_F) >= 0.0f) { p1 += w * p.y; }
    else                                   { p1 -= w * p.y; }
    if (cos(p.y * ysize * M_PI_F) >= 0.0f) { p0 += w * p.x; }
    else                                   { p0 -= w * p.x; }
    return float2(p0, p1);
}
// var31_noise (variations.c:696-708). TWO isaac_01 draws in EXACT order:
// (1) angle   tmpr = d1*2π;  sincos(tmpr, &sinr, &cosr)
// (2) radius  r = w * d2
//   (tx*r*cosr, ty*r*sinr) — INPUT-SCALED (multiplies tx, ty). The ONLY
// difference from v_blur (var34) below, which is NOT input-scaled. Paramless;
// RNG-consuming → lives in `apply_xform_body`'s w-guarded dispatch chain.
static inline float2 v_noise(float2 p, float w, thread IsaacState& rng) {
    float d1 = isaac_01(rng);                          // draw #1 (angle)
    float tmpr = d1 * 2.0f * M_PI_F;
    float cosr = cos(tmpr);
    float sinr = sin(tmpr);
    float d2 = isaac_01(rng);                          // draw #2 (radius)
    float r = w * d2;
    return float2(p.x * r * cosr, p.y * r * sinr);     // INPUT-SCALED
}
// var34_blur (variations.c:746-758). TWO isaac_01 draws — IDENTICAL draw
// structure to v_noise, but NOT input-scaled (no tx, ty factor). Paramless;
// RNG-consuming.
//   (r*cosr, r*sinr)
static inline float2 v_blur(float2 p, float w, thread IsaacState& rng) {
    (void)p;   // blur ignores its input (matches flam3 var34_blur)
    float d1 = isaac_01(rng);                          // draw #1 (angle)
    float tmpr = d1 * 2.0f * M_PI_F;
    float cosr = cos(tmpr);
    float sinr = sin(tmpr);
    float d2 = isaac_01(rng);                          // draw #2 (radius)
    float r = w * d2;
    return float2(r * cosr, r * sinr);                 // NOT input-scaled
}
// var35_gaussian (variations.c:760-773). FIVE isaac_01 draws: 1 angle + 4-sum.
// (XML name `gaussian_blur`; C function `var35_gaussian`.)
// (1) angle   ang = d1*2π;  sincos(ang, &sina, &cosa)
// (2..5) sum  r = w*(d2 + d3 + d4 + d5 - 2.0)
//   (r*cosa, r*sina). Paramless; RNG-consuming. 5 draws, NOT 4 (the angle
// draw is separate from the 4-sum).
static inline float2 v_gaussian_blur(float2 p, float w, thread IsaacState& rng) {
    (void)p;   // gaussian_blur ignores its input (matches flam3 var35_gaussian)
    float d1 = isaac_01(rng);                          // draw #1 (angle)
    float ang = d1 * 2.0f * M_PI_F;
    float sina = sin(ang);
    float cosa = cos(ang);
    float d2 = isaac_01(rng);                          // draws #2..5 (4-sum)
    float d3 = isaac_01(rng);
    float d4 = isaac_01(rng);
    float d5 = isaac_01(rng);
    float r = w * (d2 + d3 + d4 + d5 - 2.0f);
    return float2(r * cosa, r * sina);
}
// var41_arch (variations.c:857-883). ONE isaac_01 draw, UN-GUARDED sinr²/cosr:
//   ang = d1*w*π;  sincos(ang, &sinr, &cosr)
//   (w*sinr, w*(sinr*sinr)/cosr)
// NO per-term `if cosr==0` guard — match flam3 (cosr=0 → Inf; the chaos game's
// post-affine badvalue check handles Inf downstream). Paramless; RNG-consuming.
static inline float2 v_arch(float2 p, float w, thread IsaacState& rng) {
    (void)p;   // arch ignores its input (matches flam3 var41_arch)
    float d1 = isaac_01(rng);                          // draw #1 (angle)
    float ang = d1 * w * M_PI_F;
    float sinr = sin(ang);
    float cosr = cos(ang);
    return float2(w * sinr,
                  w * (sinr * sinr) / cosr);           // UN-GUARDED
}
// var43_square (variations.c:900-913). TWO isaac_01 draws, INDEPENDENT for
// p0 and p1:
//   p0 += w*(d1 - 0.5);   p1 += w*(d2 - 0.5);
// Output bounded in [-w/2, w/2]² (indep of input p). Despite the name, an
// RNG-consuming variation (the "square" shape comes from the uniform RNG
// distribution), NOT paramless. Paramless in the descriptor sense; RNG-consuming.
static inline float2 v_square(float2 p, float w, thread IsaacState& rng) {
    (void)p;   // square ignores its input (matches flam3 var43_square)
    float d1 = isaac_01(rng);                          // draw #1 (p0)
    float d2 = isaac_01(rng);                          // draw #2 (p1)
    return float2(w * (d1 - 0.5f), w * (d2 - 0.5f));
}
// var44_rays (variations.c:915-944). ONE isaac_01 draw, UN-GUARDED tan(ang):
//   ang  = w * d1 * π                                       // draw #1 (angle)
//   r    = w / (sumsq + EPS)                                // sumsq = tx²+ty²; EPS guard
//   tanr = w * tan(ang) * r                                 // UN-GUARDED (ang=π/2+kπ → Inf)
//   (tanr * cos(tx), tanr * sin(ty))
// The cos(tx)/sin(ty) are over the INPUT POINT (not the drawn angle). NO
// per-term guard on tanr — match flam3 (cosr=0 → Inf; the chaos game's
// post-affine badvalue check handles Inf downstream). Paramless; RNG-consuming.
static inline float2 v_rays(float2 p, float w, thread IsaacState& rng) {
    float d1 = isaac_01(rng);                          // draw #1 (angle)
    float ang = w * d1 * M_PI_F;
    float sumsq = p.x*p.x + p.y*p.y;                   // precalc_sumsq
    float r = w / (sumsq + EPS_MS);                    // EPS guard
    float tanr = w * tan(ang) * r;                     // UN-GUARDED
    return float2(tanr * cos(p.x),
                  tanr * sin(p.y));
}
// var45_blade (variations.c:946-974). ONE isaac_01 draw:
//   r = d1 * w * precalc_sqrt;  sincos(r, &sinr, &cosr)     // draw #1
//   p0 += w * tx * (cosr + sinr)
//   p1 += w * tx * (cosr - sinr)
// NOTE: both p0 AND p1 use `tx` (NOT ty for p1). Bounded output (no poles).
// Paramless; RNG-consuming.
static inline float2 v_blade(float2 p, float w, thread IsaacState& rng) {
    float d1 = isaac_01(rng);                          // draw #1
    float precalc_sqrt = sqrt(p.x*p.x + p.y*p.y);
    float r = d1 * w * precalc_sqrt;
    float sinr = sin(r);
    float cosr = cos(r);
    return float2(w * p.x * (cosr + sinr),
                  w * p.x * (cosr - sinr));            // BOTH use tx
}
// var47_twintrian (variations.c:998-1031). ONE isaac_01 draw, BADVALUE-GUARDED:
//   r = d1 * w * precalc_sqrt;  sincos(r, &sinr, &cosr)     // draw #1
//   diff = log10(sinr*sinr) + cosr                          // → -Inf when sinr≈0
//   if (badvalue(diff)) diff = -30.0                        // CRITICAL — see below
//   p0 += w * tx * diff
//   p1 += w * tx * (diff - sinr * π)
// The badvalue→-30.0 replacement is LOAD-BEARING for CPU↔Metal parity: without
// it, `log10(0)` returns -Inf whenever `sinr*sinr` underflows (sub-|p| ≈ 1e-162
// → sinr² → +0), and the orbit diverges. The CPU Variations.twintrian mirrors
// the EXACT same replacement using flam3's `badvalue(x) = (x != x) || (x > 1e10)
// || (x < -1e10)` (BAD_MS = 1e10). NOTE: both p0 AND p1 use `tx`. Paramless;
// RNG-consuming.
static inline float2 v_twintrian(float2 p, float w, thread IsaacState& rng) {
    float d1 = isaac_01(rng);                          // draw #1
    float precalc_sqrt = sqrt(p.x*p.x + p.y*p.y);
    float r = d1 * w * precalc_sqrt;
    float sinr = sin(r);
    float cosr = cos(r);
    float diff = log10(sinr * sinr) + cosr;
    if (badvalue_ms(diff)) diff = -30.0f;              // CRITICAL — matches flam3 + CPU
    return float2(w * p.x * diff,
                  w * p.x * (diff - sinr * M_PI_F));   // BOTH use tx
}
// var51_flower (variations.c:1118-1131). Parametric + RNG: 2 params
// (flower_holes, flower_petals [NOT flower_freq — flam3.h:302], both default 0).
// ONE isaac_01 draw. Divide by precalc_sqrt with NO +EPS (origin → 0/0 → NaN;
// match flam3 — the chaos game's post-affine badvalue check handles it).
//   theta = precalc_atanyx = atan2(ty, tx)
//   r = w * (d1 - holes) * cos(petals*theta) / precalc_sqrt   // NO EPS
//   p0 += r * tx;   p1 += r * ty
// Param order in pr[0..1] = descriptor-declared order: flower_holes, flower_petals.
static inline float2 v_flower(float2 p, float w, thread const float* pr,
                              thread IsaacState& rng) {
    float holes = pr[0], petals = pr[1];
    float theta = atan2(p.y, p.x);                     // precalc_atanyx
    float precalc_sqrt = sqrt(p.x*p.x + p.y*p.y);
    float d1 = isaac_01(rng);                          // draw #1
    float r = w * (d1 - holes) * cos(petals * theta) / precalc_sqrt;   // NO EPS
    return float2(r * p.x, r * p.y);
}
// var52_conic (variations.c:1133-1146). Parametric + RNG: 2 params
// (conic_eccentricity, conic_holes, both default 0). ONE isaac_01 draw.
// TWO divisions by precalc_sqrt with NO +EPS:
//   ct = tx / precalc_sqrt                                      // NO EPS
//   r = w * (d1 - holes) * ecc / (1 + ecc*ct) / precalc_sqrt    // NO EPS
//   p0 += r * tx;   p1 += r * ty
// NOTE: with eccentricity=0 (the parse default), r = 0 → conic outputs (0, 0).
// Param order in pr[0..1] = descriptor-declared order: conic_eccentricity, conic_holes.
static inline float2 v_conic(float2 p, float w, thread const float* pr,
                             thread IsaacState& rng) {
    float ecc = pr[0], holes = pr[1];
    float precalc_sqrt = sqrt(p.x*p.x + p.y*p.y);
    float ct = p.x / precalc_sqrt;                     // NO EPS
    float d1 = isaac_01(rng);                          // draw #1
    float r = w * (d1 - holes) * ecc
              / (1.0f + ecc * ct) / precalc_sqrt;      // NO EPS
    return float2(r * p.x, r * p.y);
}
// var53_parabola (variations.c:1148-1162). Parametric + RNG: 2 params
// (parabola_height, parabola_width, both default 0). TWO per-axis isaac_01
// draws — draw #1 → p0, draw #2 → p1 (each isaac_01 is its OWN statement; MSL
// arg-eval order is unspecified, see chaosGame kernel):
//   r = precalc_sqrt;  sincos(r, &sr, &cr)
//   p0 += height * w * sr*sr * isaac_01()              // draw #1 → p0
//   p1 += width  * w * cr      * isaac_01()            // draw #2 → p1
// Param order in pr[0..1] = descriptor-declared order: parabola_height, parabola_width.
static inline float2 v_parabola(float2 p, float w, thread const float* pr,
                                thread IsaacState& rng) {
    float height = pr[0], width = pr[1];
    float r = sqrt(p.x*p.x + p.y*p.y);                 // precalc_sqrt
    float sr = sin(r), cr = cos(r);
    float d1 = isaac_01(rng);                          // draw #1 → p0
    float p0 = height * w * sr * sr * d1;
    float d2 = isaac_01(rng);                          // draw #2 → p1
    float p1 = width  * w * cr       * d2;
    return float2(p0, p1);
}
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

// ---- 14 special-sauce (M3): Float transliterations of the Task-4 CPU closures
// in Variations.swift, which are themselves line-for-line ports of flam3
// variations.c. atan2 order per CPU closure: rings/fan/blob/fan2/rings2 use
// atan2(x,y) (flam3 precalc_atan); julian/juliascope/ngon/super_shape/
// wedge_julia/wedge_sph use atan2(y,x) (flam3 precalc_atanyx).

// var21_rings (variations.c:509-527) — coef e = c[2][0].
//   dx = e²+EPS; r = fmod(r+dx,2dx)-dx+r*(1-dx); (r*cosa, r*sina)
static inline float2 v_rings(float2 p, float w, float e) {
    float dx = e*e + EPS_MS;
    float r = sqrt(p.x*p.x + p.y*p.y);
    float a = atan2(p.x, p.y);
    r = w * (fmod(r + dx, 2.0f*dx) - dx + r*(1.0f - dx));
    return float2(r * cos(a), r * sin(a));
}
// var22_fan (variations.c:529-556) — coef e=c[2][0], f=c[2][1].
//   dx = π*(e²+EPS); dy = f; dx2 = dx/2; a += (fmod(a+dy,dx)>dx2) ? -dx2 : dx2
static inline float2 v_fan(float2 p, float w, float e, float f) {
    float dx = M_PI_F * (e*e + EPS_MS);
    float dy = f;
    float dx2 = 0.5f * dx;
    float r = w * sqrt(p.x*p.x + p.y*p.y);
    float a = atan2(p.x, p.y);
    a += (fmod(a + dy, dx) > dx2) ? -dx2 : dx2;
    return float2(r * cos(a), r * sin(a));
}
// var23_blob (variations.c:558-578). sin on x, cos on y.
static inline float2 v_blob(float2 p, float w, thread const float* pr) {
    float low = pr[0], high = pr[1], waves = pr[2];
    float r = sqrt(p.x*p.x + p.y*p.y);
    float a = atan2(p.x, p.y);
    r *= low + (high - low) * (0.5f + 0.5f*sin(waves*a));
    return float2(w * sin(a) * r, w * cos(a) * r);
}
// var25_fan2 (variations.c:599-639). sin on x, cos on y.
static inline float2 v_fan2(float2 p, float w, thread const float* pr) {
    float fan2x = pr[0], fan2y = pr[1];
    float dy = fan2y;
    float dx = M_PI_F * (fan2x*fan2x + EPS_MS);
    float dx2 = 0.5f * dx;
    float r = w * sqrt(p.x*p.x + p.y*p.y);
    float a = atan2(p.x, p.y);
    float tt = a + dy - dx * (float)((int)((a + dy) / dx));
    if (tt > dx2) { a = a - dx2; } else { a = a + dx2; }
    return float2(r * sin(a), r * cos(a));
}
// var26_rings2 (variations.c:641-658). sin on x, cos on y.
static inline float2 v_rings2(float2 p, float w, thread const float* pr) {
    float val = pr[0];
    float r = sqrt(p.x*p.x + p.y*p.y);
    float dx = val*val + EPS_MS;
    r += -2.0f*dx*(float)((int)((r + dx)/(2.0f*dx))) + r*(1.0f - dx);
    float a = atan2(p.x, p.y);
    return float2(w * sin(a) * r, w * cos(a) * r);
}
// var30_perspective (variations.c:688-695) + perspective_precalc (L1943-1947).
static inline float2 v_perspective(float2 p, float w, thread const float* pr) {
    float angle = pr[0], dist = pr[1];
    float ang = angle * M_PI_F / 2.0f;
    float vsin = sin(ang);
    float vfcos = dist * cos(ang);
    float t = 1.0f / (dist - p.y * vsin);
    return float2(w * dist * p.x * t, w * vfcos * p.y * t);
}
// var32_juliaN_generic (variations.c:711-724) + juliaN_precalc. One isaac_01.
static inline float2 v_julian(float2 p, float w, thread const float* pr,
                             thread IsaacState& rng) {
    float power = pr[0], dist = pr[1];
    float rN = fabs(power);
    float cn = dist / power / 2.0f;
    float sumsq = p.x*p.x + p.y*p.y;
    float atanyx = atan2(p.y, p.x);
    int tRnd = (int)(rN * isaac_01(rng));
    float tmpr = (atanyx + 2.0f*M_PI_F*(float)tRnd) / power;
    float r = w * pow(sumsq, cn);
    return float2(r * cos(tmpr), r * sin(tmpr));
}
// var33_juliaScope_generic (variations.c:726-745) + juliaScope_precalc. One isaac_01.
static inline float2 v_juliascope(float2 p, float w, thread const float* pr,
                                  thread IsaacState& rng) {
    float power = pr[0], dist = pr[1];
    float rN = fabs(power);
    float cn = dist / power / 2.0f;
    float sumsq = p.x*p.x + p.y*p.y;
    float atanyx = atan2(p.y, p.x);
    int tRnd = (int)(rN * isaac_01(rng));
    float tmpr;
    if ((tRnd & 1) == 0) {
        tmpr = (2.0f*M_PI_F*(float)tRnd + atanyx) / power;
    } else {
        tmpr = (2.0f*M_PI_F*(float)tRnd - atanyx) / power;
    }
    float r = w * pow(sumsq, cn);
    return float2(r * cos(tmpr), r * sin(tmpr));
}
// var38_ngon (variations.c:812-831).
static inline float2 v_ngon(float2 p, float w, thread const float* pr) {
    float sides = pr[0], power = pr[1], circle = pr[2], corners = pr[3];
    float sumsq = p.x*p.x + p.y*p.y;
    float rFactor = pow(sumsq, power / 2.0f);
    float theta = atan2(p.y, p.x);
    float b = 2.0f*M_PI_F / sides;
    float phi = theta - (b * floor(theta / b));
    if (phi > b/2.0f) { phi -= b; }
    float amp = corners * (1.0f/(cos(phi) + EPS_MS) - 1.0f) + circle;
    amp /= (rFactor + EPS_MS);
    return float2(w * p.x * amp, w * p.y * amp);
}
// var39_curl (variations.c:833-842).
static inline float2 v_curl(float2 p, float w, thread const float* pr) {
    float c1 = pr[0], c2 = pr[1];
    float re = 1.0f + c1*p.x + c2*(p.x*p.x - p.y*p.y);
    float im = c1*p.y + 2.0f*c2*p.x*p.y;
    float r = w / (re*re + im*im);
    return float2((p.x*re + p.y*im)*r, (p.y*re - p.x*im)*r);
}
// var40_rectangles (variations.c:844-856).
static inline float2 v_rectangles(float2 p, float w, thread const float* pr) {
    float rx = pr[0], ry = pr[1];
    float nx = (rx == 0.0f) ? p.x : ((2.0f*floor(p.x/rx) + 1.0f)*rx - p.x);
    float ny = (ry == 0.0f) ? p.y : ((2.0f*floor(p.y/ry) + 1.0f)*ry - p.y);
    return float2(w * nx, w * ny);
}
// var50_supershape (variations.c:1093-1117) + supershape_precalc (L2000-2003).
// Draws isaac_01 UNCONDITIONALLY (before the rnd*draw product).
static inline float2 v_super_shape(float2 p, float w, thread const float* pr,
                                   thread IsaacState& rng) {
    float rnd = pr[0], m = pr[1], n1 = pr[2], n2 = pr[3], n3 = pr[4], holes = pr[5];
    float pm4 = m / 4.0f;
    float pneg1N1 = -1.0f / n1;
    float ps = sqrt(p.x*p.x + p.y*p.y);
    float atanyx = atan2(p.y, p.x);
    float theta = pm4 * atanyx + M_PI_F / 4.0f;
    float t1 = pow(fabs(cos(theta)), n2);
    float t2 = pow(fabs(sin(theta)), n3);
    float draw = isaac_01(rng);                 // UNCONDITIONAL
    float r = w * ((rnd*draw + (1.0f-rnd)*ps) - holes) * pow(t1+t2, pneg1N1) / ps;
    return float2(r * p.x, r * p.y);
}
// var78_wedge_julia (variations.c:1672-1688) + wedgeJulia_precalc (L1954-1958). One isaac_01.
static inline float2 v_wedge_julia(float2 p, float w, thread const float* pr,
                                   thread IsaacState& rng) {
    float angle = pr[0], count = pr[1], power = pr[2], dist = pr[3];
    float cf = 1.0f - angle*count*(1.0f/M_PI_F)*0.5f;
    float rN = fabs(power);
    float cn = dist / power / 2.0f;
    float sumsq = p.x*p.x + p.y*p.y;
    float atanyx = atan2(p.y, p.x);
    float r = w * pow(sumsq, cn);
    int tRnd = (int)(rN * isaac_01(rng));
    float a = (atanyx + 2.0f*M_PI_F*(float)tRnd) / power;
    float c = floor((count*a + M_PI_F) * (1.0f/M_PI_F) * 0.5f);
    a = a*cf + c*angle;
    return float2(r * cos(a), r * sin(a));
}
// var79_wedge_sph (variations.c:1690-1709).
static inline float2 v_wedge_sph(float2 p, float w, thread const float* pr) {
    float angle = pr[0], count = pr[1], hole = pr[2], swirl = pr[3];
    float ps = sqrt(p.x*p.x + p.y*p.y);
    float r = 1.0f / (ps + EPS_MS);
    float a = atan2(p.y, p.x) + swirl * r;
    float c = floor((count*a + M_PI_F) * (1.0f/M_PI_F) * 0.5f);
    float compFac = 1.0f - angle*count*(1.0f/M_PI_F)*0.5f;
    a = a*compFac + c*angle;
    r = w * (r + hole);
    return float2(r * cos(a), r * sin(a));
}
// var37_pie (variations.c:795-809). THREE isaac_01 draws in EXACT order:
// (1) slice index    sl = (int)(d1*slices + 0.5)
// (2) angular offset (drawn INSIDE the parens of `a`):
//     a = rotation + 2π*(sl + d2*thickness) / slices
// (3) radial          r  = w * d3
//   (r*cos(a), r*sin(a)) — pie ignores `p` (output is RNG-driven only).
// Reordering any draw diverges the ISAAC stream and breaks vs-flam3 parity.
static inline float2 v_pie(float2 p, float w, thread const float* pr,
                           thread IsaacState& rng) {
    (void)p;   // pie ignores its input (matches flam3 var37_pie)
    float slices = pr[0], rotation = pr[1], thickness = pr[2];
    float d1 = isaac_01(rng);
    int sl = (int)(d1 * slices + 0.5f);                                 // draw #1
    float d2 = isaac_01(rng);
    float a = rotation + 2.0f*M_PI_F*((float)sl + d2*thickness) / slices; // draw #2
    float d3 = isaac_01(rng);                                           // draw #3
    float r = w * d3;
    return float2(r * cos(a), r * sin(a));
}
// var36_radial_blur (variations.c:775-793) + radial_blur_precalc (L1964-1967).
// FOUR isaac_01 draws summed LEFT-TO-RIGHT into a pseudo-gaussian:
//   rndG = w * (d1 + d2 + d3 + d4 - 2.0)
// The `w * (...)` outer factor means the 4 draws MUST be consumed before the
// multiply — reordering or hoisting any draw diverges the ISAAC stream. The
// 4 draws are issued as explicit ordered statements (one per line, matching
// v_pie/v_julian's convention in this file), NOT as comma-separated init-
// declarators — C++ function-argument / init-declarator evaluation order is
// fragile across MSL revisions, and any reorder would diverge the stream.
// spinvar/zoomvar are the precalc sincos of `angle*π/2` (inlined here).
//   ra   = sqrt(tx² + ty²)
//   tmpa = atan2(ty,tx) + spinvar*rndG
//   rz   = zoomvar*rndG - 1.0
//   (ra*cos(tmpa) + rz*tx, ra*sin(tmpa) + rz*ty)
static inline float2 v_radial_blur(float2 p, float w, thread const float* pr,
                                   thread IsaacState& rng) {
    float angle = pr[0];
    float spinvar = sin(angle * M_PI_F / 2.0f);
    float zoomvar = cos(angle * M_PI_F / 2.0f);
    float d1 = isaac_01(rng);                   // 4 draws, strict left-to-right
    float d2 = isaac_01(rng);
    float d3 = isaac_01(rng);
    float d4 = isaac_01(rng);
    float rndG = w * (d1 + d2 + d3 + d4 - 2.0f);
    float ra = sqrt(p.x*p.x + p.y*p.y);
    float tmpa = atan2(p.y, p.x) + spinvar * rndG;
    float rz = zoomvar * rndG - 1.0f;
    return float2(ra*cos(tmpa) + rz*p.x, ra*sin(tmpa) + rz*p.y);
}

// Sum the 55 canonical slots. julian/juliascope/super_shape/wedge_julia/pie/
// radial_blur/noise/blur/gaussian_blur/arch/square/rays/blade/twintrian/
// flower/conic/parabola also consume the RNG (julian/juliascope/wedge_julia:
// one isaac_01 each; super_shape: one UNCONDITIONAL isaac_01; pie: THREE
// ordered isaac_01s; radial_blur: FOUR isaac_01s summed left-to-right; noise:
// TWO (angle, radius) INPUT-SCALED; blur: TWO (angle, radius) NOT input-scaled;
// gaussian_blur: FIVE (1 angle + 4-sum); arch: ONE (angle); square: TWO
// (independent for p0, p1); rays: ONE (angle, un-guarded tan); blade: ONE
// (r=d1*w*sqrt); twintrian: ONE (r=d1*w*sqrt; badvalue-guarded log10(sinr²)+cosr
// → -30.0); flower: ONE (r=w*(d1-holes)*cos(petals*θ)/sqrt, NO EPS); conic:
// ONE (ct=tx/sqrt, r=w*(d1-holes)*ecc/(1+ecc*ct)/sqrt, NO EPS); parabola: TWO
// per-axis (draw #1 → p0 via height*sin²*r, draw #2 → p1 via width*cos*r)).
// CRITICAL: every slot MUST be guarded by `w[i] != 0` to match CPU
// (`Variations.evaluate` skips weight==0). Without the guard, a weight-0
// variation whose internals overflow to Inf (cosh/sinh in `cosine` for
// |p.y|>710, exp in `exponential` for |p.x|>710) yields `0.0f * Inf == NaN`,
// which contaminates `acc`, trips `badvalue_ms`, and diverges both the
// trajectory and the RNG stream from the CPU.
static inline float2 apply_xform_body(GPUXform x, float2 p, thread IsaacState& rng) {
    float2 pre = apply_affine(x, p);
    float2 acc = float2(0.0f);
    float w[NUM_XFORM_SLOTS_MS];
    for (int i = 0; i < NUM_XFORM_SLOTS_MS; i++) w[i] = x.varWeights[i];
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
    // ---- 14 special-sauce (slots 19..32, canonical order). Param pointer for
    // slot s is &x.varParams[s*SLOT_WIDTH_MS]. RNG-consuming (julian,
    // juliascope, super_shape [UNCONDITIONAL draw], wedge_julia) take `rng`. ----
    if (w[19] != 0.0f) acc += v_rings(pre, w[19], x.e);
    if (w[20] != 0.0f) acc += v_fan(pre, w[20], x.e, x.f);
    if (w[21] != 0.0f) acc += v_blob(pre, w[21], &x.varParams[21*SLOT_WIDTH_MS]);
    if (w[22] != 0.0f) acc += v_fan2(pre, w[22], &x.varParams[22*SLOT_WIDTH_MS]);
    if (w[23] != 0.0f) acc += v_rings2(pre, w[23], &x.varParams[23*SLOT_WIDTH_MS]);
    if (w[24] != 0.0f) acc += v_perspective(pre, w[24], &x.varParams[24*SLOT_WIDTH_MS]);
    if (w[25] != 0.0f) acc += v_julian(pre, w[25], &x.varParams[25*SLOT_WIDTH_MS], rng);
    if (w[26] != 0.0f) acc += v_juliascope(pre, w[26], &x.varParams[26*SLOT_WIDTH_MS], rng);
    if (w[27] != 0.0f) acc += v_ngon(pre, w[27], &x.varParams[27*SLOT_WIDTH_MS]);
    if (w[28] != 0.0f) acc += v_curl(pre, w[28], &x.varParams[28*SLOT_WIDTH_MS]);
    if (w[29] != 0.0f) acc += v_rectangles(pre, w[29], &x.varParams[29*SLOT_WIDTH_MS]);
    if (w[30] != 0.0f) acc += v_super_shape(pre, w[30], &x.varParams[30*SLOT_WIDTH_MS], rng);
    if (w[31] != 0.0f) acc += v_wedge_julia(pre, w[31], &x.varParams[31*SLOT_WIDTH_MS], rng);
    if (w[32] != 0.0f) acc += v_wedge_sph(pre, w[32], &x.varParams[32*SLOT_WIDTH_MS]);
    // slot 33 — bubble (var28_bubble, paramless, RNG-free)
    if (w[33] != 0.0f) acc += v_bubble(pre, w[33]);
    // slot 34 — eyefish (var27_eyefish, paramless, RNG-free; NOT a fisheye alias)
    if (w[34] != 0.0f) acc += v_eyefish(pre, w[34]);
    // slot 35 — pie (var37_pie, RNG-consuming; 3 ordered isaac_01 draws).
    // Param order in pr[0..2] = descriptor-declared order: slices, rotation, thickness.
    if (w[35] != 0.0f) acc += v_pie(pre, w[35], &x.varParams[35*SLOT_WIDTH_MS], rng);
    // slot 36 — radial_blur (var36_radial_blur, RNG-consuming; 4 isaac_01 draws
    // summed left-to-right into rndG = w*(d1+d2+d3+d4-2)).
    // Param order in pr[0] = descriptor-declared order: radial_blur_angle.
    if (w[36] != 0.0f) acc += v_radial_blur(pre, w[36], &x.varParams[36*SLOT_WIDTH_MS], rng);
    // ---- corpus-variations paramless non-RNG set (slots 37..41). ----
    // slot 37 — waves (var15_waves, paramless; needs affine c,d,e,f).
    if (w[37] != 0.0f) acc += v_waves(pre, w[37], x.c, x.d, x.e, x.f);
    // slot 38 — popcorn (var17_popcorn, paramless; needs affine e,f).
    if (w[38] != 0.0f) acc += v_popcorn(pre, w[38], x.e, x.f);
    // slot 39 — power (var19_power, paramless; precalc sina/cosa/sqrt).
    if (w[39] != 0.0f) acc += v_power(pre, w[39]);
    // slot 40 — tangent (var42_tangent, paramless).
    if (w[40] != 0.0f) acc += v_tangent(pre, w[40]);
    // slot 41 — cross (var48_cross, paramless).
    if (w[41] != 0.0f) acc += v_cross(pre, w[41]);
    // ---- corpus-variations parametric non-RNG set (slots 42..43). ----
    // slot 42 — pdj (var24_pdj, parametric: 4 params all default 0; 0 RNG draws).
    // Param order in pr[0..3] = descriptor-declared order: pdj_a, pdj_b, pdj_c, pdj_d.
    if (w[42] != 0.0f) acc += v_pdj(pre, w[42], &x.varParams[42*SLOT_WIDTH_MS]);
    // slot 43 — split (var74_split, parametric: 2 params default 0; 0 RNG draws).
    // Param order in pr[0..1] = descriptor-declared order: split_xsize, split_ysize.
    if (w[43] != 0.0f) acc += v_split(pre, w[43], &x.varParams[43*SLOT_WIDTH_MS]);
    // ---- corpus-variations RNG simple set (slots 44..48). All paramless but
    // RNG-consuming → take `rng`. ----
    // slot 44 — noise (var31_noise, 2 isaac_01 draws, INPUT-SCALED: tx*r*cosr).
    if (w[44] != 0.0f) acc += v_noise(pre, w[44], rng);
    // slot 45 — blur (var34_blur, 2 isaac_01 draws, NOT input-scaled: r*cosr).
    if (w[45] != 0.0f) acc += v_blur(pre, w[45], rng);
    // slot 46 — gaussian_blur (var35_gaussian, 5 isaac_01 draws: 1 angle + 4-sum).
    if (w[46] != 0.0f) acc += v_gaussian_blur(pre, w[46], rng);
    // slot 47 — arch (var41_arch, 1 isaac_01 draw, UN-GUARDED sinr²/cosr).
    if (w[47] != 0.0f) acc += v_arch(pre, w[47], rng);
    // slot 48 — square (var43_square, 2 isaac_01 draws, bounded in [-w/2, w/2]²).
    if (w[48] != 0.0f) acc += v_square(pre, w[48], rng);
    // ---- corpus-variations RNG + Inf/badvalue care set (slots 49..51). All
    // paramless; exactly 1 isaac_01 draw each → take `rng`. ----
    // slot 49 — rays (var44_rays, 1 isaac_01 draw; UN-GUARDED tan(ang), r=w/(sumsq+EPS)).
    if (w[49] != 0.0f) acc += v_rays(pre, w[49], rng);
    // slot 50 — blade (var45_blade, 1 isaac_01 draw; both p0,p1 use tx).
    if (w[50] != 0.0f) acc += v_blade(pre, w[50], rng);
    // slot 51 — twintrian (var47_twintrian, 1 isaac_01 draw; BADVALUE-GUARDED
    // log10(sinr²)+cosr → -30.0 — load-bearing for CPU↔Metal parity).
    if (w[51] != 0.0f) acc += v_twintrian(pre, w[51], rng);
    // ---- corpus-variations parametric + RNG hybrid set (slots 52..54). All
    // have 2 params (default 0) + 1..2 isaac_01 draws → take `pr` AND `rng`. ----
    // slot 52 — flower (var51_flower, 1 isaac_01 draw; params flower_holes +
    // flower_petals [NOT flower_freq]; r=w*(d1-holes)*cos(petals*θ)/sqrt NO EPS).
    // Param order in pr[0..1] = descriptor-declared order: flower_holes, flower_petals.
    if (w[52] != 0.0f) acc += v_flower(pre, w[52], &x.varParams[52*SLOT_WIDTH_MS], rng);
    // slot 53 — conic (var52_conic, 1 isaac_01 draw; params conic_eccentricity +
    // conic_holes; TWO /sqrt NO EPS — ct=tx/sqrt, r=.../sqrt).
    // Param order in pr[0..1] = descriptor-declared order: conic_eccentricity, conic_holes.
    if (w[53] != 0.0f) acc += v_conic(pre, w[53], &x.varParams[53*SLOT_WIDTH_MS], rng);
    // slot 54 — parabola (var53_parabola, 2 per-axis isaac_01 draws; params
    // parabola_height + parabola_width; draw #1 → p0 via height*sin²*r,
    // draw #2 → p1 via width*cos*r).
    // Param order in pr[0..1] = descriptor-declared order: parabola_height, parabola_width.
    if (w[54] != 0.0f) acc += v_parabola(pre, w[54], &x.varParams[54*SLOT_WIDTH_MS], rng);
    return apply_post(x, acc);
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

// MARK: - GPU resident decode (AtomicBin → FloatBin)
//
// Converts the chaos kernel's fixed-point `AtomicBin` histogram (5×uint32,
// atomic-accumulated, associative → byte-deterministic) into the `FloatBin`
// (5×float) layout Stages 2/3 consume, IN PLACE on the GPU — so the histogram
// never crosses to the CPU between stages. r/g/b/a are divided by `colorScale`
// to recover dmap-units, matching the host decode in `ChaosGameMetal.decode`
// (`Double(bin.c) * (1.0/colorScale)` rounded to Float; `float(u)/s` is the
// correctly-rounded IEEE equivalent for the in-range uint32 values here).
// `count` is the raw hit count as float.
//
// Pure per-bin map — NO atomics, NO order dependence. It runs in its own
// compute encoder after the chaos encoder (single command buffer → encoder
// ordering gives full write visibility), so the atomic_uint loads read settled
// values. Determinism is unchanged: chaos still writes uint32 atomics; this
// kernel only READS them and WRITES non-atomic floats.
kernel void atomicBinToFloatBin(device const AtomicBin* atomicIn [[buffer(0)]],
                                device FloatBin* floatOut        [[buffer(1)]],
                                constant const GPUFrameParams* fp [[buffer(2)]],
                                uint2 tid [[thread_position_in_grid]]) {
    uint gw = fp->gridWidth, gh = fp->gridHeight;
    if (tid.x >= gw || tid.y >= gh) return;
    uint idx = tid.y * gw + tid.x;
    uint c = atomic_load_explicit(&atomicIn[idx].count, memory_order_relaxed);
    uint r = atomic_load_explicit(&atomicIn[idx].r,   memory_order_relaxed);
    uint g = atomic_load_explicit(&atomicIn[idx].g,   memory_order_relaxed);
    uint b = atomic_load_explicit(&atomicIn[idx].b,   memory_order_relaxed);
    uint a = atomic_load_explicit(&atomicIn[idx].a,   memory_order_relaxed);
    float s = fp->colorScale;
    floatOut[idx].count = float(c);
    floatOut[idx].r = float(r) / s;
    floatOut[idx].g = float(g) / s;
    floatOut[idx].b = float(b) / s;
    floatOut[idx].a = float(a) / s;
}

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

// HSV conversion for `calc_newrgb`'s saturated-highlight branch
// (palettes.c:318-332). Used only when `maxa > 255 && highpow >= 0` — i.e.,
// real genomes with `highlight_power >= 0`. Faithful MSL twin of CPU
// `rgb2hsv`/`hsv2rgb` in ToneMapping.swift (lines 219-254). Computes in float
// (the CPU uses Double); CPU↔Metal parity on real genomes holds at the
// project's statistical threshold (≥38 dB), not byte-exact.
static inline float3 rgb2hsv_ms(float3 rgb) {
    float mx = max(rgb.x, max(rgb.y, rgb.z));
    float mn = min(rgb.x, min(rgb.y, rgb.z));
    float d = mx - mn;
    float s = (mx > 0.0f) ? d / mx : 0.0f;
    float h = 0.0f;
    if (d > 0.0f) {
        if (mx == rgb.x) {
            h = (rgb.y - rgb.z) / d;
        } else if (mx == rgb.y) {
            h = (rgb.z - rgb.x) / d + 2.0f;
        } else {
            h = (rgb.x - rgb.y) / d + 4.0f;
        }
        h /= 6.0f;
        if (h < 0.0f) h += 1.0f;
    }
    return float3(h, s, mx);
}

static inline float3 hsv2rgb_ms(float3 hsv) {
    float h6 = hsv.x * 6.0f;
    float c = hsv.y * hsv.z;
    float x = c * (1.0f - fabs(fmod(h6, 2.0f) - 1.0f));
    float m = hsv.z - c;
    float3 out;
    if (h6 < 1.0f)        out = float3(c, x, 0);
    else if (h6 < 2.0f)   out = float3(x, c, 0);
    else if (h6 < 3.0f)   out = float3(0, c, x);
    else if (h6 < 4.0f)   out = float3(0, x, c);
    else if (h6 < 5.0f)   out = float3(x, 0, c);
    else                  out = float3(c, 0, x);
    return float3(out.x + m, out.y + m, out.z + m);
}

// palettes.c:292-348. The `if (maxa > 255 && highpow >= 0)` branch (HSV
// desaturation, palettes.c:318-332) is unreachable at the default
// highlightPower=-1, but real ES genomes set `highlight_power="1"` which makes
// `maxa > 255` the normal saturated-peak case. CPU ToneMapping has the same
// branch (ToneMapping.swift:163-173); this Metal twin mirrors it byte-for-byte
// modulo Float-vs-Double math so CPU↔Metal parity holds on real genomes.
static inline float3 calc_newrgb(float3 cbuf, float ls, float highpow) {
    if (ls == 0 || (cbuf.x == 0 && cbuf.y == 0 && cbuf.z == 0)) return 0.0f;
    float maxa = -1.0f; float maxc = 0.0f;
    for (int i = 0; i < 3; i++) {
        float a = ls * (cbuf[i] / PREFILTER_WHITE_MS);
        if (a > maxa) { maxa = a; maxc = cbuf[i] / PREFILTER_WHITE_MS; }
    }
    if (maxa > 255.0f && highpow >= 0.0f) {
        // Highlight anti-shift (palettes.c:318-332): compress the saturated
        // channel back to 255 via `newls = 255/maxc`, then desaturate by
        // `lsratio = pow(newls/ls, highpow)`. Pulls peaks down and spreads
        // them across the upper-mid range — exactly the [64,128) bump and
        // [128,256) dip that without this branch made Emberweft "peakier"
        // than flam3 by ~28 dB on real genomes.
        float newls = 255.0f / maxc;
        float lsratio = pow(newls / ls, highpow);
        float3 newrgb = float3(newls * cbuf.x / PREFILTER_WHITE_MS / 255.0f,
                               newls * cbuf.y / PREFILTER_WHITE_MS / 255.0f,
                               newls * cbuf.z / PREFILTER_WHITE_MS / 255.0f);
        float3 hsv = rgb2hsv_ms(newrgb);
        hsv = float3(hsv.x, hsv.y * lsratio, hsv.z);
        return hsv2rgb_ms(hsv) * 255.0f;
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
