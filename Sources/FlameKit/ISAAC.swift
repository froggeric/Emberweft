import Foundation

// A faithful Swift port of flam3's ISAAC PRNG.
//
// This is a deliberate, line-for-line port of flam3's `isaac.c`, `isaac.h`,
// and `isaacs.h` (as built locally on macOS LP64). It exists so that
// Emberweft's CPU reference renderer reproduces flam3's RNG-dependent
// variations (julia, noise, blur, fan, ...) byte-for-byte.
//
// Source of truth: `~/flam3-oracle-src/flam3/{isaac.c,isaac.h,isaacs.h}`.
//
// FAITHFULNESS NOTES (verified against the C harness
// `~/flam3-oracle-src/isaac_check`):
//
// - flam3's `isaacs.h` declares `typedef unsigned long int ub4;`. On macOS
//   LP64, `sizeof(unsigned long int) == 8`, so each ISAAC word is stored in
//   an 8-byte slot. `isaac.h` sets `RANDSIZL = 4`, `RANDSIZ = 1<<4 = 16`.
//   The generation step (`rngstep`) masks every value with `& 0xffffffff`,
//   so produced words are always 32-bit — but the *initialization* `mix()`
//   macro does NOT mask, so 64-bit overflow semantics during `randinit`
//   affect the final state. We therefore model `mm`/`randrsl`/`aa`/`bb`/`cc`
//   as `UInt64` and apply `& 0xffffffff` exactly where the C does.
// - flam3's seeding model (`flam3.c:2497-2515`): `memset(randrsl, 0,
//   RANDSIZ*sizeof(ub4))`, then `strncpy((char*)&randrsl, isaac_seed,
//   RANDSIZ*sizeof(ub4))` when a seed string is supplied, then
//   `irandinit(&ctx, 1)`. We mirror the byte layout exactly: the seed
//   string's UTF-8 bytes are laid into a 128-byte little-endian buffer
//   (zero-padded), interpreted as 16 `UInt64` slots.
// - Consumption order matches flam3's `irand()` macro: the first `isaac()`
//   batch (produced inside `randinit`) is consumed index 15→0, then a fresh
//   batch is generated and consumed 15→0, and so on.

/// RANDSIZL — log2 of the ISAAC results/internal-table size.
///
/// From `isaac.h`: `#define RANDSIZL (4)` (flam3 uses the simulation size,
/// not the crypto size of 8).
@usableFromInline
internal let ISAAC_RANDSIZL: Int = 4

/// RANDSIZ — number of ISAAC words per results/internal table.
/// From `isaac.h`: `#define RANDSIZ (1<<RANDSIZL)` → 16.
@usableFromInline
internal let ISAAC_RANDSIZ: Int = 1 << ISAAC_RANDSIZL

/// ISAAC — faithful port of flam3's PRNG (Bob Jenkins' ISAAC, 32-bit output,
/// RANDSIZ=16 variant as used by flam3).
///
/// `Sendable` value type; state is mutated through `mutating func next()`.
/// Deterministic and pure: no clocks, no system entropy.
public struct ISAAC: Sendable {

    // MARK: - State (mirrors `struct randctx` from isaac.h)
    //
    // Modelled as UInt64 to match `unsigned long int` on macOS LP64. The
    // generation step keeps every value masked to 32 bits, so the externally
    // observable stream is 32-bit.

    /// `randcnt` — countdown into the current results batch. After `randinit`
    /// it is `RANDSIZ`; consumption decrements it.
    @usableFromInline internal private(set) var randcnt: UInt64

    /// `randrsl[]` — the results buffer (also the seed input).
    @usableFromInline internal private(set) var randrsl: [UInt64]

    /// `randmem[]` (named `mm` in the original) — internal state table.
    @usableFromInline internal private(set) var mm: [UInt64]

    /// `randa`, `randb`, `randc` — accumulators carried between batches.
    @usableFromInline internal private(set) var aa: UInt64
    @usableFromInline internal private(set) var bb: UInt64
    @usableFromInline internal private(set) var cc: UInt64

    // MARK: - Initialization

    /// Seed exactly as flam3 does when an `isaac_seed` string is supplied
    /// (`flam3.c:2497-2515`): the seed bytes are `strncpy`'d into `randrsl`
    /// (zero-padded to `RANDSIZ * sizeof(ub4)` = 128 bytes), then
    /// `irandinit(ctx, 1)` is called.
    ///
    /// - Parameter isaacSeed: The seed string (treated as raw bytes, matching
    ///   C `char *` semantics). Pass `""` for the empty-string seed; this is
    ///   distinct from flam3's `NULL` path which falls back to `time(0)`.
    public init(isaacSeed: String) {
        self.randrsl = Self.parseSeedBytes(isaacSeed)
        self.mm = [UInt64](repeating: 0, count: ISAAC_RANDSIZ)
        self.aa = 0
        self.bb = 0
        self.cc = 0
        self.randcnt = UInt64(ISAAC_RANDSIZ)
        self.randinit(flag: true)
    }

    /// Seed directly from a 16-word `randrsl` buffer, mirroring flam3's
    /// per-thread ISAAC seeding (rect.c:862-865): the render loop draws
    /// `RANDSIZ` words from the frame-level ("parent") ISAAC and uses them
    /// to `irandinit(child, 1)` a thread-local ISAAC. This initializer
    /// reproduces that path so the chaos-game stream matches flam3's exactly.
    ///
    /// Each word is treated as a 32-bit value in a 64-bit slot (high 32 bits
    /// ignored), matching `ub4` on macOS LP64.
    public init(randrsl: [UInt64]) {
        precondition(randrsl.count == ISAAC_RANDSIZ,
                     "randrsl must have exactly \(ISAAC_RANDSIZ) words")
        self.randrsl = randrsl.map { $0 & 0xffffffff }
        self.mm = [UInt64](repeating: 0, count: ISAAC_RANDSIZ)
        self.aa = 0
        self.bb = 0
        self.cc = 0
        self.randcnt = UInt64(ISAAC_RANDSIZ)
        self.randinit(flag: true)
    }

    /// Lay a seed string into a 128-byte buffer exactly like flam3's
    /// `memset` + `strncpy`, then read it back as 16 little-endian `UInt64`s.
    ///
    /// `strncpy(dst, src, n)` copies `src`'s bytes (up to the first `'\0'`,
    /// which it includes) and zero-fills the remainder up to `n` bytes. We
    /// pre-zero the buffer and copy the raw UTF-8 bytes (without terminator),
    /// which is equivalent on a pre-zeroed buffer for any seed whose byte
    /// length is < `n`; for length ≥ `n` both truncate at `n` with no NUL.
    private static func parseSeedBytes(_ seed: String) -> [UInt64] {
        let capacity = ISAAC_RANDSIZ * MemoryLayout<UInt64>.size  // 16 * 8 = 128
        var bytes = [UInt8](repeating: 0, count: capacity)
        let src = Array(seed.utf8)
        let n = Swift.min(src.count, capacity)
        for i in 0..<n {
            bytes[i] = src[i]
        }
        // Interpret as 16 little-endian UInt64s (host is little-endian on
        // Apple Silicon; this matches the C build's in-memory layout).
        var words = [UInt64](repeating: 0, count: ISAAC_RANDSIZ)
        for w in 0..<ISAAC_RANDSIZ {
            var v: UInt64 = 0
            // Little-endian: byte[0] is the least significant.
            for b in 0..<MemoryLayout<UInt64>.size {
                v |= UInt64(bytes[w * MemoryLayout<UInt64>.size + b]) << (b * 8)
            }
            words[w] = v
        }
        return words
    }

    // MARK: - `irand()` (the public consumption entry point)

    /// Return the next 32-bit pseudo-random word, matching flam3's `irand()`
    /// macro expansion. The batch is consumed index `RANDSIZ-1` → `0`; when
    /// exhausted, a fresh batch is generated via `isaac()`.
    @discardableResult
    public mutating func next() -> UInt32 {
        // flam3: #define irand(r) \
        //   (!(r)->randcnt-- ? \
        //     (isaac(r), (r)->randcnt=RANDSIZ-1, (r)->randrsl[(r)->randcnt]) : \
        //     (r)->randrsl[(r)->randcnt])
        if randcnt == 0 {
            isaac()
            randcnt = UInt64(ISAAC_RANDSIZ - 1)
        } else {
            randcnt = randcnt &- 1
        }
        // randrsl values are always masked to 32 bits by `isaac()`, so this
        // truncation is lossless and exact.
        return UInt32(truncatingIfNeeded: randrsl[Int(randcnt)])
    }

    /// `flam3_random_isaac_bit` (flam3.c:2541-2544): one full ISAAC word
    /// consumed, lowest bit returned. This is the per-iteration π-bit used by
    /// the julia variation (variations.c:364).
    @inlinable
    public mutating func bit() -> Bool {
        (next() & 1) != 0
    }

    /// `flam3_random_isaac_01` (flam3.c:2519-2521):
    /// `((int)irand(ct) & 0xfffffff) / (double)0xfffffff` → uniform in [0, 1].
    /// The `(int)` cast is a no-op for the 28-bit masked value. Returns Double
    /// matching flam3's double result exactly (no Float intermediary).
    @inlinable
    public mutating func isaac01() -> Double {
        let v = UInt32(next() & 0xfffffff)
        return Double(v) / Double(UInt32(0xfffffff))
    }

    /// `flam3_random_isaac_11` (flam3.c:2523-2525):
    /// `(((int)irand(ct) & 0xfffffff) - 0x7ffffff) / (double)0x7ffffff`
    /// → uniform in [-1, 1].
    @inlinable
    public mutating func isaac11() -> Double {
        let v = UInt32(next() & 0xfffffff)
        return (Double(v) - Double(UInt32(0x7ffffff))) / Double(UInt32(0x7ffffff))
    }

    // MARK: - `randinit` / `irandinit`

    /// Port of `irandinit(randctx *ctx, word flag)` from isaac.c.
    ///
    /// `flag == true` ⇒ use `randrsl[]` (the seed) to initialize `mm[]`;
    /// `flag == false` ⇒ zero-path. flam3 always calls with `flag == 1`.
    private mutating func randinit(flag: Bool) {
        aa = 0; bb = 0; cc = 0

        // Golden ratio; C uses `0x9e3779b9` stored in an 8-byte ub4.
        var a: UInt64 = 0x9e3779b9
        var b: UInt64 = 0x9e3779b9
        var c: UInt64 = 0x9e3779b9
        var d: UInt64 = 0x9e3779b9
        var e: UInt64 = 0x9e3779b9
        var f: UInt64 = 0x9e3779b9
        var g: UInt64 = 0x9e3779b9
        var h: UInt64 = 0x9e3779b9

        // `for (i=0; i<4; ++i) mix(...);`
        for _ in 0..<4 {
            Self.mix(&a, &b, &c, &d, &e, &f, &g, &h)
        }

        if flag {
            // Pass 1: fold randrsl (the seed) into mm.
            var i = 0
            while i < ISAAC_RANDSIZ {
                a = a &+ randrsl[i]
                b = b &+ randrsl[i + 1]
                c = c &+ randrsl[i + 2]
                d = d &+ randrsl[i + 3]
                e = e &+ randrsl[i + 4]
                f = f &+ randrsl[i + 5]
                g = g &+ randrsl[i + 6]
                h = h &+ randrsl[i + 7]
                Self.mix(&a, &b, &c, &d, &e, &f, &g, &h)
                mm[i] = a; mm[i + 1] = b; mm[i + 2] = c; mm[i + 3] = d
                mm[i + 4] = e; mm[i + 5] = f; mm[i + 6] = g; mm[i + 7] = h
                i += 8
            }
            // Pass 2: make all of the seed affect all of mm.
            i = 0
            while i < ISAAC_RANDSIZ {
                a = a &+ mm[i]
                b = b &+ mm[i + 1]
                c = c &+ mm[i + 2]
                d = d &+ mm[i + 3]
                e = e &+ mm[i + 4]
                f = f &+ mm[i + 5]
                g = g &+ mm[i + 6]
                h = h &+ mm[i + 7]
                Self.mix(&a, &b, &c, &d, &e, &f, &g, &h)
                mm[i] = a; mm[i + 1] = b; mm[i + 2] = c; mm[i + 3] = d
                mm[i + 4] = e; mm[i + 5] = f; mm[i + 6] = g; mm[i + 7] = h
                i += 8
            }
        } else {
            var i = 0
            while i < ISAAC_RANDSIZ {
                Self.mix(&a, &b, &c, &d, &e, &f, &g, &h)
                mm[i] = a; mm[i + 1] = b; mm[i + 2] = c; mm[i + 3] = d
                mm[i + 4] = e; mm[i + 5] = f; mm[i + 6] = g; mm[i + 7] = h
                i += 8
            }
        }

        isaac()                       // fill the first result batch
        randcnt = UInt64(ISAAC_RANDSIZ)  // prepare to consume from the top
    }

    // MARK: - `isaac()` generation

    /// Port of `isaac(randctx *ctx)` from isaac.c.
    ///
    /// Generates one full batch (`RANDSIZ` words) into `randrsl`. Each value
    /// is masked to 32 bits exactly as in `rngstep`.
    private mutating func isaac() {
        // a = ctx->randa; b = (ctx->randb + (++ctx->randc)) & 0xffffffff;
        cc = cc &+ 1
        var a = aa
        var b = (bb &+ cc) & 0xffffffff

        // ind(mm, x) = mm[(x >> 2) & (RANDSIZ - 1)]
        // The two loops cover m=0..7 with m2=8..15, then m=8..15 with m2=0..7.
        var m = 0
        var m2 = ISAAC_RANDSIZ / 2

        // First loop: m in [0,8), m2 in [8,16).
        while m < ISAAC_RANDSIZ / 2 {
            Self.rngstep(a << 13, &a, &b, &mm, &m, &m2, &randrsl)
            Self.rngstep(a >> 6,  &a, &b, &mm, &m, &m2, &randrsl)
            Self.rngstep(a << 2,  &a, &b, &mm, &m, &m2, &randrsl)
            Self.rngstep(a >> 16, &a, &b, &mm, &m, &m2, &randrsl)
        }
        // Second loop: m in [8,16), m2 in [0,8).
        m2 = 0
        while m2 < ISAAC_RANDSIZ / 2 {
            Self.rngstep(a << 13, &a, &b, &mm, &m, &m2, &randrsl)
            Self.rngstep(a >> 6,  &a, &b, &mm, &m, &m2, &randrsl)
            Self.rngstep(a << 2,  &a, &b, &mm, &m, &m2, &randrsl)
            Self.rngstep(a >> 16, &a, &b, &mm, &m, &m2, &randrsl)
        }

        bb = b
        aa = a
    }

    /// Port of the `rngstep(mix, a, b, mm, m, m2, r, x)` macro.
    ///
    /// Operates on the internal `UInt64` model; every stored result is masked
    /// to 32 bits exactly as the C original. `mixExpr` is `a<<13`, `a>>6`,
    /// `a<<2`, or `a>>16` evaluated against the current `a`.
    @usableFromInline
    internal static func rngstep(
        _ mixExpr: UInt64,
        _ a: inout UInt64,
        _ b: inout UInt64,
        _ mm: inout [UInt64],
        _ m: inout Int,
        _ m2: inout Int,
        _ r: inout [UInt64]
    ) {
        // x = *m;
        let x = mm[m]
        // a = ((a ^ (mix)) + *(m2++)) & 0xffffffff;
        a = ((a ^ mixExpr) &+ mm[m2]) & 0xffffffff
        m2 += 1
        // *(m++) = y = (ind(mm, x) + a + b) & 0xffffffff;
        // ind(mm, x) = mm[(x >> 2) & (RANDSIZ - 1)]
        let y = (mm[Int((x >> 2) & UInt64(ISAAC_RANDSIZ - 1))] &+ a &+ b) & 0xffffffff
        mm[m] = y
        m += 1
        // *(r++) = b = (ind(mm, y >> RANDSIZL) + x) & 0xffffffff;
        // ind(mm, y >> RANDSIZL) = mm[((y >> RANDSIZL) >> 2) & (RANDSIZ - 1)]
        // (y is already masked to 32 bits.)
        let idx = Int(((y >> UInt64(ISAAC_RANDSIZL)) >> 2) & UInt64(ISAAC_RANDSIZ - 1))
        b = (mm[idx] &+ x) & 0xffffffff
        r[m - 1] = b
    }

    /// Port of the `mix(a,b,c,d,e,f,g,h)` macro.
    ///
    /// Runs WITHOUT 32-bit masking, exactly as the C original — this is
    /// load-bearing for parity because `ub4` is 8 bytes wide on macOS LP64.
    @usableFromInline
    internal static func mix(
        _ a: inout UInt64,
        _ b: inout UInt64,
        _ c: inout UInt64,
        _ d: inout UInt64,
        _ e: inout UInt64,
        _ f: inout UInt64,
        _ g: inout UInt64,
        _ h: inout UInt64
    ) {
        a ^= (b << 11); d = d &+ a; b = b &+ c
        b ^= (c >> 2);  e = e &+ b; c = c &+ d
        c ^= (d << 8);  f = f &+ c; d = d &+ e
        d ^= (e >> 16); g = g &+ d; e = e &+ f
        e ^= (f << 10); h = h &+ e; f = f &+ g
        f ^= (g >> 4);  a = a &+ f; g = g &+ h
        g ^= (h << 8);  b = b &+ g; h = h &+ a
        h ^= (a >> 9);  c = c &+ h; a = a &+ b
    }
}
