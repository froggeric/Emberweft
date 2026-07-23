import Foundation

/// SINGLE SOURCE OF TRUTH for all variation metadata: the canonical 99-slot
/// order (M1's 19 + the 14 NEW special-sauce + bubble + eyefish + pie +
/// radial_blur + waves/popcorn/power/tangent/cross + pdj/split +
/// noise/blur/gaussian_blur/arch/square + rays/blade/twintrian +
/// flower/conic/parabola + secant2/disc2 + trig family + paramless non-trig
/// + parametric batches 3a/3b + boarders/cpow/pre_blur; spherical/polar
/// counted once), per-variation params/defaults,
/// special-sauce rest values, and the name→(slot, intra-slot-index) maps.
/// Shared by the parser, serializer, CPU `Variations` table, the Metal host
/// packer, and `apply_xform_body` dispatch. `Variations.canonicalOrder` IS a
/// one-line re-export of this array (landed in Task 5, which also grew
/// `GPUXform.varWeights` to `[36]` and the MSL if-chain, so the widening was
/// atomic). `VariationDescriptor.canonicalOrder` is the 99-name authority
/// used by all code paths, and `Variations.canonicalOrder` simply re-exports
/// it. Pinned to the spec's "Param-channel layout" + "Special-sauce padding"
/// tables.
public struct VariationDescriptor: Sendable {
    public let name: String
    public let parameters: [String]                 // ordered (intra-slot order)
    public let defaults: [String: Double]
    public let rest: [String: Double]               // special-sauce rest; key absent => stays at default

    // ---- canonical slot order (the 99-device-slot layout) ----
    /// Fixed 99-name order. First 19 == the M1 set (in its existing order, so the
    /// M1 Metal host `idxMap`/CPU `evaluate` stay slot-stable); then the 14 NEW
    /// special-sauce names in documented order; then `bubble` (var28) and
    /// `eyefish` (var27), both paramless/RNG-free, appended at slots 33/34 to
    /// preserve existing slots 0..32; then `pie` (var37, RNG-consuming, slot 35)
    /// and `radial_blur` (var36, RNG-consuming, slot 36); then the corpus-
    /// variations paramless non-RNG set: `waves` (var15, needs affine c,d,e,f),
    /// `popcorn` (var17, e,f), `power` (var19, precalc sina/cosa), `tangent`
    /// (var42), `cross` (var48) at slots 37..41; then the corpus-variations
    /// RNG simple set: `noise` (var31, 2 draws, INPUT-SCALED), `blur` (var34,
    /// 2 draws, NOT input-scaled), `gaussian_blur` (var35, 5 draws), `arch`
    /// (var41, 1 draw, un-guarded sinr²/cosr), `square` (var43, 2 draws) at
    /// slots 44..48; then the corpus-variations RNG + Inf/badvalue care set:
    /// `rays` (var44, 1 draw, un-guarded tan(ang)), `blade` (var45, 1 draw),
    /// `twintrian` (var47, 1 draw, badvalue→-30.0 guard on log10(sinr²)+cosr)
    /// at slots 49..51; then the corpus-variations parametric + RNG hybrid set:
    /// `flower` (var51, 1 draw, params flower_holes + flower_petals [NOT
    /// flower_freq], /sqrt NO EPS), `conic` (var52, 1 draw, params
    /// conic_eccentricity + conic_holes, TWO /sqrt NO EPS), `parabola` (var53,
    /// 2 per-axis draws, params parabola_height + parabola_width) at slots
    /// 52..54; then the corpus-variations final pair: `secant2` (var46,
    /// paramless, un-guarded 1/cos), `disc2` (var49, parametric disc2_rot/
    /// disc2_twist default 0, precalc inlined) at slots 55..56. The 2 final
    /// corpus slots brought Emberweft to 57/99 (100% of the variations that
    /// appear in the 23k-genome corpus survey); the trig family var82–95
    /// (slots 57..70) extends Emberweft to 71/99, the paramless non-trig
    /// family (var57/61/62/64/66/70/72, slots 71..77) extends Emberweft to
    /// 78/99, the parametric ≤2-params non-RNG family (var54/55/58/63/97/68/
    /// 75/76/80, slots 78..86) extends Emberweft to 87/99, the parametric
    /// 3+-params non-RNG family (var96/60/65/98/71/73/81/77/69, slots 87..95)
    /// extends Emberweft to 96/99, and the final RNG family (var56 boarders,
    /// var59 cpow, var67 pre_blur, slots 96..98) extends Emberweft to 99/99
    /// — full flam3 coverage.
    /// spherical/polar appear ONCE.
    public static let canonicalOrder: [String] = [
        // --- M1's 19 (do not reorder: existing slots 0..18) ---
        "bent","cosine","cylinder","diamond","disc","ex","exponential","fisheye",
        "handkerchief","heart","horseshoe","hyperbolic","julia","linear","polar",
        "sinusoidal","spherical","spiral","swirl",
        // --- 14 NEW special-sauce (slots 19..32) ---
        "rings","fan","blob","fan2","rings2","perspective","julian","juliascope",
        "ngon","curl","rectangles","super_shape","wedge_julia","wedge_sph",
        // --- var28_bubble (slot 33): paramless, RNG-free; unblocks 05739/31943 ---
        "bubble",
        // --- var27_eyefish (slot 34): paramless, RNG-free; NOT a fisheye alias
        //     (un-swapped output). Unblocks 00000 (partially; pie/radial_blur still pending). ---
        "eyefish",
        // --- var37_pie (slot 35): 3 ordered isaac_01 draws (slice, angular,
        //     radial). RNG-consuming → lives in `evaluate`'s switch, NOT the
        //     table. Unblocks 00000 (partially; radial_blur still pending). ---
        "pie",
        // --- var36_radial_blur (slot 36): 4 isaac_01 draws summed left-to-right
        //     into rndG = weight*(d1+d2+d3+d4-2.0). RNG-consuming → lives in
        //     `evaluate`'s switch, NOT the table. Unblocks 00000 (the last
        //     `.knownGap` fixture). ---
        "radial_blur",
        // --- corpus-variations paramless non-RNG set (slots 37..41). Each is
        //     paramless + 0 RNG draws → lives in the table closures, NOT
        //     `evaluate`'s switch. Verified formulas against
        //     /private/tmp/flam3-build/variations.c (Task 1 CV1). ---
        // var15_waves: needs affine c,d,e,f (waves_dx2=1/(e²+EPS), dy2=1/(f²+EPS))
        "waves",
        // var17_popcorn: needs affine e,f
        "popcorn",
        // var19_power: precalc sina/cosa/sqrt
        "power",
        // var42_tangent
        "tangent",
        // var48_cross
        "cross",
        // --- corpus-variations parametric non-RNG set (slots 42..43). Both are
        //     parametric (4 + 2 params) with default 0 + 0 RNG draws → live in
        //     the table closures, NOT `evaluate`'s switch. Verified formulas
        //     against /private/tmp/flam3-build/variations.c (Task 2 CV2). ---
        // var24_pdj: 4 params (pdj_a/b/c/d), all default 0.
        "pdj",
        // var74_split: 2 params (split_xsize/ysize), default 0. p1 branch FIRST
        // in C source (observationally equivalent — p0/p1 accumulate separately).
        "split",
        // --- corpus-variations RNG simple set (slots 44..48). All paramless but
        //     RNG-consuming (1..5 isaac_01 draws each) → live in `evaluate`'s
        //     switch, NOT the closure table. Verified formulas against
        //     /private/tmp/flam3-build/variations.c (Task 3 CV3). ---
        // var31_noise: 2 draws; INPUT-SCALED output (multiplies tx, ty).
        "noise",
        // var34_blur: 2 draws; NOT input-scaled (no tx, ty factor).
        "blur",
        // var35_gaussian_blur: 5 draws (1 angle + 4-sum into w*(Σ-2)).
        "gaussian_blur",
        // var41_arch: 1 draw; UN-GUARDED sinr²/cosr (no per-term guard; matches flam3).
        "arch",
        // var43_square: 2 draws; output bounded in [-w/2, w/2]² (indep of input).
        "square",
        // --- corpus-variations RNG + Inf/badvalue care set (slots 49..51). All
        //     paramless; exactly 1 isaac_01 draw each. Verified formulas against
        //     /private/tmp/flam3-build/variations.c (Task 4 CV4). ---
        // var44_rays: 1 draw; UN-GUARDED tan(ang) (ang=w*d1*π → Inf at ang=π/2+kπ).
        "rays",
        // var45_blade: 1 draw; r=d1*w*sqrt, p0=w*tx*(cosr+sinr), p1=w*tx*(cosr-sinr).
        "blade",
        // var47_twintrian: 1 draw; BADVALUE-GUARDED log10(sinr²)+cosr → -30.0
        // (BOTH CPU+Metal — the load-bearing care item).
        "twintrian",
        // --- corpus-variations parametric + RNG hybrid set (slots 52..54). All
        //     have 2 params (default 0) and 1..2 isaac_01 draws → live in
        //     `evaluate`'s switch, NOT the table. Verified formulas against
        //     /private/tmp/flam3-build/variations.c (Task 5 CV5). ---
        // var51_flower: 1 draw; params flower_holes + flower_petals (NOT flower_freq);
        // r = w*(d1-holes)*cos(petals*atanyx)/sqrt — /sqrt with NO +EPS.
        "flower",
        // var52_conic: 1 draw; params conic_eccentricity + conic_holes;
        // ct = tx/sqrt (NO EPS); r = w*(d1-holes)*ecc/(1+ecc*ct)/sqrt (NO EPS).
        "conic",
        // var53_parabola: 2 per-axis draws (p0 first via height*sin²*r, then p1
        // via width*cos*r); params parabola_height + parabola_width.
        "parabola",
        // --- corpus-variations final pair (CV7): the last 2 corpus-used flam3
        //     variations (slots 55..56). Brings Emberweft to 57/99 — 100% of the
        //     variations that appear in the 23k-genome corpus survey. Both are
        //     non-RNG → live in the table closures, NOT `evaluate`'s switch.
        //     Verified formulas against /private/tmp/flam3-build/variations.c. ---
        // var46_secant2: paramless; UN-GUARDED 1/cos (cr=0 → Inf; match flam3).
        "secant2",
        // var49_disc2: parametric (disc2_rot, disc2_twist, default 0);
        // disc2_precalc (timespi/cosadd/sinadd) inlined into the closure.
        "disc2",
        // --- Trig family (Z+ variations): var82_exp .. var95_coth (slots 57..70) ---
        // All paramless; 0 RNG draws. Formulas ported verbatim from
        // /private/tmp/flam3-build/variations.c L1747-1897. Brings Emberweft to
        // 71/99 variations.
        // var82_exp: expe = exp(tx); sincos(ty, &expsin, &expcos)
        "exp",
        // var83_log: (w * 0.5 * log(sumsq), w * atan2(y, x))
        "log",
        // var84_sin: sincos(tx, &sinsin, &sinacos); sinhsinh = sinh(ty); sincosh = cosh(ty)
        "sin",
        // var85_cos: sincos(tx, &cossin, &coscos); coshsinh = sinh(ty); coshcosh = cosh(ty)
        "cos",
        // var86_tan: sincos(2*tx, &tansin, &tancos); tanhsinh = sinh(2*ty); tanhcosh = cosh(2*ty)
        "tan",
        // var87_sec: secden = 2/(cos(2*tx) + cosh(2*ty))
        "sec",
        // var88_csc: cscden = 2/(cosh(2*ty) - cos(2*tx))
        "csc",
        // var89_cot: cotden = 1/(cotcosh - cotcos)
        "cot",
        // var90_sinh: sincos(ty, &sinhsin, &sinhcos); sinhsinh = sinh(tx); sinhcosh = cosh(tx)
        "sinh",
        // var91_cosh: sincos(ty, &coshsin, &coshcos); coshsinh = sinh(tx); coshcosh = cosh(tx)
        "cosh",
        // var92_tanh: tanhden = 1/(tanhcos + tanhcosh)
        "tanh",
        // var93_sech: sechden = 2/(cos(2*ty) + cosh(2*tx))
        "sech",
        // var94_csch: cschden = 2/(cosh(2*tx) - cos(2*ty))
        "csch",
        // var95_coth: cothden = 1/(cothcosh - cothcos)
        "coth",
        // ---- Batch 2: paramless non-trig (var57/61/62/64/66/70/72; slots 71..77) ----
        // All paramless; 0 RNG draws. Formulas ported verbatim from
        // /Users/frederic/flam3-oracle-src/flam3/variations.c L1238-1590. Brings
        // Emberweft to 78/99 variations.
        // var57_butterfly: wx=w*1.3029400317411197908970256609023; y2=ty*2;
        //   r=wx*sqrt(|ty*tx|/(EPS+tx²+y2²))
        "butterfly",
        // var61_edisc: r1=sqrt(sumsq+1+2tx); r2=sqrt(sumsq+1-2tx); xmax=(r1+r2)/2;
        //   a1=log(xmax+sqrt(xmax-1)); a2=-acos(tx/xmax); w=w/11.57034632;
        //   if(ty>0) snv=-snv; (w*cshu*csv, w*snhu*snv)
        "edisc",
        // var62_elliptic: tmp=sumsq+1; x2=2tx; xmax=(sqrt(tmp+x2)+sqrt(tmp-x2))/2;
        //   a=tx/xmax; b=max(0,1-a²); ssx=max(0,xmax-1); w=w/M_PI_2;
        //   (w*atan2(a,b), ±w*log(xmax+ssx))
        "elliptic",
        // var64_foci: expx=exp(tx)*0.5; expnx=0.25/expx; sincos(ty,&sn,&cn);
        //   tmp=w/(expx+expnx-cn); (tmp*(expx-expnx), tmp*sn)
        "foci",
        // var66_loonie: r2=sumsq; w2=w²; if r2<w2: r=w*sqrt(w2/r2-1);
        //   (r*tx, r*ty) else (w*tx, w*ty). NO EPS (origin → div-by-zero).
        "loonie",
        // var70_polar2: p2v=w/M_PI; (p2v*precalc_atan, p2v/2*log(sumsq))
        //   precalc_atan = atan2(tx,ty) (SWAPPED — flam3's polar angle).
        "polar2",
        // var72_scry: t=sumsq; r=1/(precalc_sqrt*(t+1/(w+EPS)));
        //   (tx*r, ty*r). Note: weight folded only inside 1/(w+EPS).
        "scry",
        // ---- Batch 3a: parametric ≤2-params non-RNG (var54/55/58/63/97/68/75/
        // 76/80; slots 78..86) ----
        // All parametric (1 or 2 params, ALL defaults 0); 0 RNG draws. Formulas
        // ported verbatim from /Users/frederic/flam3-oracle-src/flam3/variations.c
        // L1164-1730. Brings Emberweft to 87/99 variations.
        // var54_bent2: 2 params bent2_x/bent2_y; nx*=bent2_x if nx<0, ny*=bent2_y
        //   if ny<0; (w*nx, w*ny).
        "bent2",
        // var55_bipolar: 1 param bipolar_shift; uses precalc_sumsq;
        //   ps=-π/2*shift; y=0.5*atan2(2ty, sumsq-1)+ps; wrap to [-π/2,π/2];
        //   p0=w*0.25*(2/π)*log((t+x2)/(t-x2)); p1=w*(2/π)*y.
        "bipolar",
        // var58_cell: 1 param cell_size; int x=floor(tx/cs),y=floor(ty/cs);
        //   interleave cells by quadrant; NOTE p1 SUBTRACTS: p0=w*(dx+x*cs),
        //   p1=-(w*(dy+y*cs)).
        "cell",
        // var63_escher: 1 param escher_beta; uses precalc_sumsq, precalc_atanyx;
        //   vc=0.5*(1+cosβ), vd=0.5*sinβ; m=w*exp(vc*lnr-vd*a);
        //   n=vc*a+vd*lnr; (m*cos n, m*sin n).
        "escher",
        // var97_flux: 1 param flux_spread; xpw=tx+w, xmw=tx-w;
        //   avgr=w*(2+spread)*sqrt(sqrt(ty²+xpw²)/sqrt(ty²+xmw²));
        //   avga=(atan2(ty,xmw)-atan2(ty,xpw))*0.5; (avgr*cos avga, avgr*sin avga).
        "flux",
        // var68_modulus: 2 params modulus_x/y; xr=2*mx, yr=2*my; branchy fold
        //   of tx/ty back into [-mx,mx]/[-my,my] via fmod; (w*nx, w*ny).
        "modulus",
        // var75_splits: 2 params splits_x/y. ⚠️ DIFFERENT from var74 split —
        //   adds ±splits_x/y by sign of tx/ty: (w*(tx±sx), w*(ty±sy)).
        "splits",
        // var76_stripes: 2 params stripes_space/stripes_warp;
        //   roundx=floor(tx+0.5); offsetx=tx-roundx;
        //   p0=w*(offsetx*(1-space)+roundx); p1=w*(ty+offsetx²*warp).
        "stripes",
        // var80_whorl: 2 params whorl_inside/whorl_outside; uses precalc_sqrt,
        //   precalc_atanyx; if r<w: a=θ+inside/(w-r) else a=θ+outside/(w-r);
        //   (w*r*cos a, w*r*sin a). NOTE: weight is in the denominator (non-
        //   standard; singular at r==weight — match flam3).
        "whorl",
        // ---- Batch 3b: parametric 3+-params non-RNG (var96/60/65/98/71/73/81/
        // 77/69; slots 87..95) ----
        // All parametric (3..8 params, ALL defaults 0); 0 RNG draws. Formulas
        // ported verbatim from /Users/frederic/flam3-oracle-src/flam3/variations.c
        // L1312-1928. Brings Emberweft to 96/99 variations.
        // var96_auger: 4 params auger_freq/scale/sym/weight; sign-sym sinusoidal
        //   perturbation of dx, dy; p1 = w*dy, p0 = w*(tx+sym*(dx-tx)).
        "auger",
        // var60_curve: 4 params curve_xamp/xlength/yamp/ylength; Gaussian bump
        //   per axis; pc_xlen/pc_ylen clamped to 1E-20 (NOT EPS — match source).
        "curve",
        // var65_lazysusan: 5 params lazysusan_space/spin/twist/x/y; ⚠️ y=ty+y,
        //   p1 -= y (signs are asymmetric — match source verbatim).
        "lazysusan",
        // var98_mobius: 8 params mobius_re_a/b/c/d + mobius_im_a/b/c/d; complex
        //   Möbius transform (re_u/im_u/re_v/im_v); weight / |v|² prefactor.
        //   Uses ALL 8 slot params (slotWidth=8).
        "mobius",
        // var71_popcorn2: 3 params popcorn2_c/x/y; p0 += w*(tx + x·sin(tan(c·ty))),
        //   p1 += w*(ty + y·sin(tan(c·tx))).
        "popcorn2",
        // var73_separation: 4 params separation_x/xinside/y/yinside; per-axis
        //   sqrt(tx²+sx²) ∓ tx·xinside by sign of tx; same for ty.
        "separation",
        // var81_waves2: 4 params waves2_freqx/freqy/scalex/scaley;
        //   p0 += w*(tx + scalex·sin(ty·freqx)), p1 += w*(ty + scaley·sin(tx·freqy)).
        //   ⚠️ DIFFERENT from var15 waves (paramless, uses affine c,d,e,f).
        "waves2",
        // var77_wedge: 4 params wedge_angle/count/hole/swirl; uses precalc_sqrt,
        //   precalc_atanyx. ⚠️ DIFFERENT from var78 wedge_julia (RNG) and
        //   var79 wedge_sph (1/r) — wedge uses r directly (no 1/r).
        "wedge",
        // var69_oscope: 3 params oscilloscope_separation/frequency/amplitude;
        //   genome attr is `oscilloscope` (parser.c maps oscilloscope_* →
        //   oscope_*). 4th C param oscope_damping defaults 0 → simpler branch
        //   (exp damping factor) only — exposed here as 3 params per spec.
        "oscilloscope",
        // ---- Batch 4: RNG family (var56/59/67; slots 96..98). Brings Emberweft
        // to 99/99 — full flam3 coverage. boarders + cpow are NORMAL
        // accumulator variations dispatched in `evaluate`'s switch + the MSL
        // w-guarded chain (with rng). pre_blur is a PRE-transform: it mutates
        // the input point AFTER the affine but BEFORE the variation loop (5
        // isaac_01 draws), so it is NOT in the evaluate switch / MSL dispatch
        // chain — see ChaosGame.applyXformBody + apply_xform_body's pre-step. ----
        // var56_boarders: paramless, 1 isaac_01 draw, normal accumulator.
        //   rint = round-to-nearest-EVEN (banker's); branchy offsetX/offsetY
        //   boarder-walk (divisions guarded by |offsetX|>=|offsetY| structure;
        //   origin → NaN is handled downstream by badvalue, no guard).
        "boarders",
        // var59_cpow: parametric (cpow_r/cpow_i/cpow_power, default 0) + 1
        //   isaac_01 draw INSIDE floor(cpow_power * isaac_01). Uses
        //   precalc_atanyx + precalc_sumsq. RNG-consuming → evaluate switch.
        "cpow",
        // var67_pre_blur: paramless, 5 isaac_01 draws (4 summed into rndG
        //   left-to-right + 1 into rndA), a PRE-transform that mutates (tx,ty)
        //   after the affine before the variation loop. Has a descriptor +
        //   knownNames + canonicalOrder slot (parses + packs) but NO table
        //   closure + NO evaluate-switch case — applied as a pre-step in
        //   ChaosGame.applyXformBody (CPU) + apply_xform_body (Metal).
        "pre_blur",
    ]
    /// Canonical device-slot index for a variation name (0..<99), or nil if unknown.
    public static func canonicalSlot(for name: String) -> Int? {
        canonicalOrder.firstIndex(of: name)
    }
    /// Intra-slot param index (0..<MAX_PARAMS_PER_SLOT). Used by the Metal host
    /// packer and mirrored implicitly by the MSL per-variation functions.
    public static func slotIndex(variation: String, param: String) -> Int {
        guard let d = descriptor(for: variation) else { return 0 }
        return d.parameters.firstIndex(of: param) ?? 0
    }
    public static let maxParamsPerSlot = 6          // driven by super_shape

    public static func descriptor(for name: String) -> VariationDescriptor? { table[name] }

    /// Resolve a parametric XML attr key against the known tables. Returns nil for
    /// a plain variation-weight attr (e.g. "linear", "curl" with no suffix) or an
    /// unknown param suffix.
    ///
    /// Each param is stored under its FULL XML name (`blob_low`, `fan2_x`,
    /// `super_shape_n3`, …) — NOT the short suffix — so the serializer's
    /// `for p in d.parameters` emit loop produces `blob_low="…"` verbatim and
    /// `evaluate`/`v_blob` read the same key from `parameters`. Therefore the
    /// matcher checks the FULL `key` against `d.parameters` (after a `hasPrefix`
    /// gate as a fast-path intent check). Stripping the prefix and checking the
    /// short suffix would ALWAYS miss (there is no "low" entry, only "blob_low")
    /// — do not revert to that.
    ///
    /// "At most one hit" is guaranteed by param-name UNIQUENESS (no two variations
    /// share a full param key), independent of prefix distinctness; the `hasPrefix`
    /// gate is not load-bearing for uniqueness, only an optimization + clarity guard.
    public static func matchParamAttribute(_ key: String) -> (variation: String, param: String)? {
        for (varName, d) in table where !d.parameters.isEmpty {
            if key.hasPrefix(varName + "_") && d.parameters.contains(key) {
                return (varName, key)   // param == full XML name (e.g. "blob_low")
            }
        }
        return nil
    }

    // name -> (ordered params, defaults, rest-overrides). Covers ALL 38 canonical
    // names so canonicalOrder and the descriptor table cannot drift. Defaults/rest
    // source-cited to flam3.h / parser.c / variations.c in the spec param table.
    private static let table: [String: VariationDescriptor] = {
        var t: [String: VariationDescriptor] = [:]
        func d(_ name: String, _ params: [String], _ defaults: [String: Double],
               _ rest: [String: Double] = [:]) {
            t[name] = VariationDescriptor(name: name, parameters: params, defaults: defaults, rest: rest)
        }
        // --- M1's 19 (all parameterless; every canonicalOrder name must be
        //     registered so the order table and descriptor table cannot drift) ---
        d("bent", [], [:]); d("cosine", [], [:]); d("cylinder", [], [:]); d("diamond", [], [:])
        d("disc", [], [:]); d("ex", [], [:]); d("exponential", [], [:]); d("fisheye", [], [:])
        d("handkerchief", [], [:]); d("heart", [], [:]); d("horseshoe", [], [:]); d("hyperbolic", [], [:])
        d("julia", [], [:]); d("linear", [], [:]); d("polar", [], [:])        // Group A
        d("sinusoidal", [], [:]); d("spherical", [], [:])                     // Group A
        d("spiral", [], [:]); d("swirl", [], [:])
        d("bubble", [], [:])     // var28_bubble: paramless, RNG-free (slot 33)
        d("eyefish", [], [:])    // var27_eyefish: paramless, RNG-free (slot 34; NOT a fisheye alias)
        // var37_pie (slot 35): 3 ordered isaac_01 draws. RNG-consuming → lives in
        // `evaluate`'s switch (mirrors julian), NOT the closure table.
        d("pie", ["pie_slices","pie_rotation","pie_thickness"],
          ["pie_slices":6,"pie_rotation":0,"pie_thickness":0.5])
        // var36_radial_blur (slot 36): 4 isaac_01 draws summed left-to-right
        // into rndG = weight*(d1+d2+d3+d4-2). RNG-consuming → lives in
        // `evaluate`'s switch, NOT the closure table.
        d("radial_blur", ["radial_blur_angle"], ["radial_blur_angle":0])
        // --- corpus-variations paramless non-RNG set (slots 37..41) ---
        // var15_waves (paramless; needs affine c,d,e,f)
        d("waves", [], [:])
        // var17_popcorn (paramless; needs affine e,f)
        d("popcorn", [], [:])
        // var19_power (paramless; precalc sina/cosa/sqrt)
        d("power", [], [:])
        // var42_tangent (paramless)
        d("tangent", [], [:])
        // var48_cross (paramless)
        d("cross", [], [:])
        // --- corpus-variations parametric non-RNG set (slots 42..43) ---
        // var24_pdj (4 params, all default 0 — flam3 clear_cp is preceded by
        // memset(0) on the genome in parser.c:229, and none of pdj_a/b/c/d are
        // explicitly initialized in clear_cp → missing XML attrs parse as 0).
        d("pdj", ["pdj_a","pdj_b","pdj_c","pdj_d"],
          ["pdj_a":0,"pdj_b":0,"pdj_c":0,"pdj_d":0])
        // var74_split (2 params, default 0; p1 branch FIRST in C source).
        d("split", ["split_xsize","split_ysize"],
          ["split_xsize":0,"split_ysize":0])
        // --- corpus-variations RNG simple set (slots 44..48). All paramless;
        //     RNG-consuming → live in `evaluate`'s switch, NOT the table. ---
        // var31_noise (2 draws, INPUT-SCALED)
        d("noise", [], [:])
        // var34_blur (2 draws, NOT input-scaled)
        d("blur", [], [:])
        // var35_gaussian_blur (5 draws: 1 angle + 4-sum)
        d("gaussian_blur", [], [:])
        // var41_arch (1 draw, un-guarded sinr²/cosr)
        d("arch", [], [:])
        // var43_square (2 draws, bounded in [-w/2, w/2]²)
        d("square", [], [:])
        // --- corpus-variations RNG + Inf/badvalue care set (slots 49..51). All
        //     paramless; exactly 1 isaac_01 draw each → live in `evaluate`'s
        //     switch, NOT the table. ---
        // var44_rays (1 draw, un-guarded tan(ang))
        d("rays", [], [:])
        // var45_blade (1 draw; both p0,p1 use tx)
        d("blade", [], [:])
        // var47_twintrian (1 draw, badvalue→-30.0 on log10(sinr²)+cosr)
        d("twintrian", [], [:])
        // --- corpus-variations parametric + RNG hybrid set (slots 52..54). All
        //     have 2 params (default 0) and 1..2 isaac_01 draws → live in
        //     `evaluate`'s switch, NOT the table. flam3 `clear_cp` does NOT
        //     initialize any of these params (memset(0) in parser.c:229 wins) →
        //     missing XML attrs parse as 0. `conic_eccentricity=1.0` exists only
        //     in `initialize_xforms` (newly-added xforms, NOT parsing) → mirror 0. ---
        // var51_flower (1 draw; params flower_holes + flower_petals [NOT flower_freq])
        d("flower", ["flower_holes","flower_petals"],
          ["flower_holes":0,"flower_petals":0])
        // var52_conic (1 draw; params conic_eccentricity + conic_holes)
        d("conic", ["conic_eccentricity","conic_holes"],
          ["conic_eccentricity":0,"conic_holes":0])
        // var53_parabola (2 per-axis draws; params parabola_height + parabola_width)
        d("parabola", ["parabola_height","parabola_width"],
          ["parabola_height":0,"parabola_width":0])
        // --- corpus-variations final pair (CV7). Both non-RNG (secant2 paramless;
        //     disc2 parametric). Disc2's `disc2_timespi`/`disc2_sinadd`/
        //     `disc2_cosadd` are derived by `disc2_precalc` inlined into the
        //     closure (NOT XML params). flam3 `clear_cp` does NOT initialize
        //     disc2_rot/twist → missing XML attrs parse as 0 (memset(0) in
        //     parser.c:229 wins), same as pdj/split/flower/conic/parabola. ---
        // var46_secant2 (paramless; UN-GUARDED 1/cos)
        d("secant2", [], [:])
        // var49_disc2 (parametric: disc2_rot, disc2_twist, default 0)
        d("disc2", ["disc2_rot","disc2_twist"],
          ["disc2_rot":0,"disc2_twist":0])
        // --- Trig family (Z+ variations): var82_exp .. var95_coth (slots 57..70) ---
        // All paramless; 0 RNG draws. Formulas ported verbatim from
        // /private/tmp/flam3-build/variations.c L1747-1897.
        // var82_exp: expe = exp(tx); sincos(ty, &expsin, &expcos)
        d("exp", [], [:])
        // var83_log: (w * 0.5 * log(sumsq), w * atan2(y, x))
        d("log", [], [:])
        // var84_sin: sincos(tx, &sinsin, &sinacos); sinhsinh = sinh(ty); sincosh = cosh(ty)
        d("sin", [], [:])
        // var85_cos: sincos(tx, &cossin, &coscos); coshsinh = sinh(ty); coshcosh = cosh(ty)
        d("cos", [], [:])
        // var86_tan: sincos(2*tx, &tansin, &tancos); tanhsinh = sinh(2*ty); tanhcosh = cosh(2*ty)
        d("tan", [], [:])
        // var87_sec: secden = 2/(cos(2*tx) + cosh(2*ty))
        d("sec", [], [:])
        // var88_csc: cscden = 2/(cosh(2*ty) - cos(2*tx))
        d("csc", [], [:])
        // var89_cot: cotden = 1/(cotcosh - cotcos)
        d("cot", [], [:])
        // var90_sinh: sincos(ty, &sinhsin, &sinhcos); sinhsinh = sinh(tx); sinhcosh = cosh(tx)
        d("sinh", [], [:])
        // var91_cosh: sincos(ty, &coshsin, &coshcos); coshsinh = sinh(tx); coshcosh = cosh(tx)
        d("cosh", [], [:])
        // var92_tanh: tanhden = 1/(tanhcos + tanhcosh)
        d("tanh", [], [:])
        // var93_sech: sechden = 2/(cos(2*ty) + cosh(2*tx))
        d("sech", [], [:])
        // var94_csch: cschden = 2/(cosh(2*tx) - cos(2*ty))
        d("csch", [], [:])
        // var95_coth: cothden = 1/(cothcosh - cothcos)
        d("coth", [], [:])
        // --- End trig family (14 variations) ---
        // --- Batch 2: paramless non-trig (var57/61/62/64/66/70/72; slots 71..77) ---
        // All paramless; 0 RNG draws. Formulas ported verbatim from
        // /Users/frederic/flam3-oracle-src/flam3/variations.c L1238-1590.
        d("butterfly", [], [:])
        d("edisc", [], [:])
        d("elliptic", [], [:])
        d("foci", [], [:])
        d("loonie", [], [:])
        d("polar2", [], [:])
        d("scry", [], [:])
        // --- End batch 2 (7 variations) ---
        // --- Batch 3a: parametric ≤2-params non-RNG (9 variations). All
        //     parametric; 0 RNG draws → live in the closure table, NOT
        //     `evaluate`'s switch. Formulas ported verbatim from
        //     /Users/frederic/flam3-oracle-src/flam3/variations.c. flam3
        //     `clear_cp` does NOT initialize ANY of these params (memset(0) in
        //     parser.c:229 wins) → missing XML attrs parse as 0, exactly like
        //     pdj/split. ---
        // var54_bent2 (2 params, default 0): nx*=bent2_x if nx<0; ny*=bent2_y if ny<0.
        d("bent2", ["bent2_x","bent2_y"],
          ["bent2_x":0,"bent2_y":0])
        // var55_bipolar (1 param, default 0): uses precalc_sumsq; ps=-π/2*shift;
        //   y=0.5*atan2(2ty, sumsq-1)+ps, wrapped to [-π/2,π/2].
        d("bipolar", ["bipolar_shift"],
          ["bipolar_shift":0])
        // var58_cell (1 param, default 0): int-cell interleave; p1 SUBTRACTS.
        d("cell", ["cell_size"],
          ["cell_size":0])
        // var63_escher (1 param, default 0): complex-log-power; precalc_sumsq/atanyx.
        d("escher", ["escher_beta"],
          ["escher_beta":0])
        // var97_flux (1 param, default 0): xpw=tx+w, xmw=tx-w.
        d("flux", ["flux_spread"],
          ["flux_spread":0])
        // var68_modulus (2 params, default 0): branchy fmod fold.
        d("modulus", ["modulus_x","modulus_y"],
          ["modulus_x":0,"modulus_y":0])
        // var75_splits (2 params, default 0): ⚠️ DIFFERENT from var74 split
        //   (split_xsize/ysize). Adds ±splits_x/y by sign of tx/ty.
        d("splits", ["splits_x","splits_y"],
          ["splits_x":0,"splits_y":0])
        // var76_stripes (2 params, default 0): roundx=floor(tx+0.5).
        d("stripes", ["stripes_space","stripes_warp"],
          ["stripes_space":0,"stripes_warp":0])
        // var80_whorl (2 params, default 0): weight in denominator (non-standard).
        d("whorl", ["whorl_inside","whorl_outside"],
          ["whorl_inside":0,"whorl_outside":0])
        // --- End batch 3a (9 variations) ---
        // --- Batch 3b: parametric 3+-params non-RNG (9 variations). All
        //     parametric (3..8 params); 0 RNG draws → live in the closure table,
        //     NOT `evaluate`'s switch. Formulas ported verbatim from
        //     /Users/frederic/flam3-oracle-src/flam3/variations.c. flam3
        //     `clear_cp` does NOT initialize ANY of these params (memset(0) in
        //     parser.c:229 wins) → missing XML attrs parse as 0, exactly like
        //     batch 3a. `oscilloscope` is the XML name; the C struct field is
        //     `oscope_*` (parser.c:1140-1155 maps both forms) — Emberweft uses
        //     the XML form (`oscilloscope_*`) everywhere, like flam3 genomes. ---
        // var96_auger (4 params, default 0): s=sin(freq·tx), t=sin(freq·ty);
        //   dy=ty+weight*(scale·s/2+|ty|·s); dx=tx+weight*(scale·t/2+|tx|·t);
        //   p0=w*(tx+sym*(dx-tx)); p1=w*dy.
        d("auger", ["auger_freq","auger_scale","auger_sym","auger_weight"],
          ["auger_freq":0,"auger_scale":0,"auger_sym":0,"auger_weight":0])
        // var60_curve (4 params, default 0): pc_xlen/xlength² clamped to 1E-20
        //   (NOT EPS — match source); p0 += w*(tx + xamp·exp(-ty²/pc_xlen));
        //   p1 += w*(ty + yamp·exp(-tx²/pc_ylen)).
        d("curve", ["curve_xamp","curve_xlength","curve_yamp","curve_ylength"],
          ["curve_xamp":0,"curve_xlength":0,"curve_yamp":0,"curve_ylength":0])
        // var65_lazysusan (5 params, default 0): ⚠️ asymmetric signs:
        //   x=tx-lazysusan_x, y=ty+lazysusan_y; p0 += ... +lazysusan_x;
        //   p1 += ... -lazysusan_y. if r<w inside-branch else outside-branch.
        d("lazysusan", ["lazysusan_space","lazysusan_spin","lazysusan_twist","lazysusan_x","lazysusan_y"],
          ["lazysusan_space":0,"lazysusan_spin":0,"lazysusan_twist":0,"lazysusan_x":0,"lazysusan_y":0])
        // var98_mobius (8 params, default 0): complex Möbius transform. Uses all
        //   8 slot params (slotWidth=8 — MAX_PARAMS_PER_SLOT=6 is a stale comment
        //   and NOT enforced by the packer; `intraIdx < slotWidth` = 8 holds).
        d("mobius",
          ["mobius_re_a","mobius_re_b","mobius_re_c","mobius_re_d",
           "mobius_im_a","mobius_im_b","mobius_im_c","mobius_im_d"],
          ["mobius_re_a":0,"mobius_re_b":0,"mobius_re_c":0,"mobius_re_d":0,
           "mobius_im_a":0,"mobius_im_b":0,"mobius_im_c":0,"mobius_im_d":0])
        // var71_popcorn2 (3 params, default 0): p0 += w*(tx + x·sin(tan(c·ty)));
        //   p1 += w*(ty + y·sin(tan(c·tx))).
        d("popcorn2", ["popcorn2_c","popcorn2_x","popcorn2_y"],
          ["popcorn2_c":0,"popcorn2_x":0,"popcorn2_y":0])
        // var73_separation (4 params, default 0): per-axis branchy sqrt fold.
        d("separation", ["separation_x","separation_xinside","separation_y","separation_yinside"],
          ["separation_x":0,"separation_xinside":0,"separation_y":0,"separation_yinside":0])
        // var81_waves2 (4 params, default 0): ⚠️ DIFFERENT from var15 waves
        //   (paramless, uses affine c,d,e,f) — waves2 is parametric sinusoidal.
        d("waves2", ["waves2_freqx","waves2_freqy","waves2_scalex","waves2_scaley"],
          ["waves2_freqx":0,"waves2_freqy":0,"waves2_scalex":0,"waves2_scaley":0])
        // var77_wedge (4 params, default 0): ⚠️ DIFFERENT from var78 wedge_julia
        //   (RNG) and var79 wedge_sph (1/r+EPS) — wedge uses precalc_sqrt directly
        //   (no 1/r, no EPS); r = weight*(sqrt + hole).
        d("wedge", ["wedge_angle","wedge_count","wedge_hole","wedge_swirl"],
          ["wedge_angle":0,"wedge_count":0,"wedge_hole":0,"wedge_swirl":0])
        // var69_oscope (3 params, default 0): XML name `oscilloscope`, C field
        //   `oscope_*`. 4th C param oscope_damping NOT exposed (defaults 0 →
        //   damping=0 branch only; spec contract = 3 params).
        d("oscilloscope", ["oscilloscope_separation","oscilloscope_frequency","oscilloscope_amplitude"],
          ["oscilloscope_separation":0,"oscilloscope_frequency":0,"oscilloscope_amplitude":0])
        // --- End batch 3b (9 variations) ---
        // --- Batch 4: RNG family (var56/59/67). boarders + cpow are RNG-
        // consuming normal accumulators → live in `evaluate`'s switch, NOT the
        // table. pre_blur is a PRE-transform (mutates input after affine, BEFORE
        // the variation loop) → has NO table closure AND NO evaluate-switch case
        // (handled by ChaosGame.applyXformBody's pre-step). Formulas ported
        // verbatim from /Users/frederic/flam3-oracle-src/flam3/variations.c. ---
        // var56_boarders (paramless, 1 isaac_01 draw): RNG-consuming → evaluate
        //   switch. The descriptor is paramless (no XML params).
        d("boarders", [], [:])
        // var59_cpow (3 params cpow_r/i/power, default 0; 1 isaac_01 draw):
        //   RNG-consuming → evaluate switch. cpow_power=0 (the parse default)
        //   is a flam3 singularity (2π/power, r/power, i/power → ±Inf/NaN);
        //   genomes always set a nonzero power.
        d("cpow", ["cpow_r","cpow_i","cpow_power"],
          ["cpow_r":0,"cpow_i":0,"cpow_power":0])
        // var67_pre_blur (paramless, 5 isaac_01 draws; PRE-transform). NOT in
        //   the table closure AND NOT in evaluate's switch — applied as a pre-
        //   step in ChaosGame.applyXformBody + apply_xform_body (Metal). The
        //   descriptor exists only so the parser accepts `pre_blur="..."`
        //   weights and the Metal host packer writes the weight to slot 98.
        d("pre_blur", [], [:])
        // --- End batch 4 (3 variations) ---
        // --- 14 NEW special-sauce ---
        d("rings", [], [:])                            // Group C (swap-affine, no params)
        d("fan", [], [:])                              // Group C
        d("blob", ["blob_low","blob_high","blob_waves"],
          ["blob_low":0,"blob_high":1,"blob_waves":1],
          ["blob_low":1,"blob_high":1,"blob_waves":1])
        d("curl", ["curl_c1","curl_c2"], ["curl_c1":1,"curl_c2":0], ["curl_c1":0,"curl_c2":0])
        d("rectangles", ["rectangles_x","rectangles_y"], ["rectangles_x":1,"rectangles_y":1], ["rectangles_x":0,"rectangles_y":0])
        d("fan2", ["fan2_x","fan2_y"], ["fan2_x":0,"fan2_y":0], ["fan2_x":0,"fan2_y":0])
        d("rings2", ["rings2_val"], ["rings2_val":0], ["rings2_val":0])
        d("perspective", ["perspective_angle","perspective_dist"],
          ["perspective_angle":0,"perspective_dist":0], ["perspective_angle":0])  // dist KEPT
        d("super_shape", ["super_shape_rnd","super_shape_m","super_shape_n1","super_shape_n2","super_shape_n3","super_shape_holes"],
          ["super_shape_rnd":0,"super_shape_m":0,"super_shape_n1":1,"super_shape_n2":1,"super_shape_n3":1,"super_shape_holes":0],
          ["super_shape_rnd":0,"super_shape_n1":2,"super_shape_n2":2,"super_shape_n3":2,"super_shape_holes":0])  // m KEPT
        d("ngon", ["ngon_sides","ngon_power","ngon_circle","ngon_corners"],
          ["ngon_sides":5,"ngon_power":3,"ngon_circle":1,"ngon_corners":2])
        d("julian", ["julian_power","julian_dist"], ["julian_power":1,"julian_dist":1])
        d("juliascope", ["juliascope_power","juliascope_dist"], ["juliascope_power":1,"juliascope_dist":1])
        d("wedge_julia", ["wedge_julia_angle","wedge_julia_count","wedge_julia_power","wedge_julia_dist"],
          ["wedge_julia_angle":0,"wedge_julia_count":1,"wedge_julia_power":1,"wedge_julia_dist":0])
        d("wedge_sph", ["wedge_sph_angle","wedge_sph_count","wedge_sph_hole","wedge_sph_swirl"],
          ["wedge_sph_angle":0,"wedge_sph_count":1,"wedge_sph_hole":0,"wedge_sph_swirl":0])
        return t
    }()
}
