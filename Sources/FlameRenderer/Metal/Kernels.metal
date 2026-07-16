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
