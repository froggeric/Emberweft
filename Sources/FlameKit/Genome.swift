import Foundation

/// A 2D affine transform matching flam3's coefficient convention.
///
/// The `coefs = "a b c d e f"` string is parsed into `c[3][2]` row-major
/// (`c[k][j] = v[k*2+j]`, flam3 `parser.c:974`) and applied as the matrix
/// `| a c e |`
/// `| b d f |` (flam3 `variations.c:2145-2146`):
///
/// ```
/// x' = a·x + c·y + e
/// y' = b·x + d·y + f
/// ```
public struct AffineTransform: Sendable, Equatable {
    public var a, b, c, d, e, f: Double
    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        (self.a, self.b, self.c, self.d, self.e, self.f) = (a, b, c, d, e, f)
    }

    /// Identity transform: maps every point to itself (a=1, d=1).
    public static let identity = AffineTransform(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    /// Apply the transform to a 2D point using the flam3 convention.
    public func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2<Double>(a * p.x + c * p.y + e, b * p.x + d * p.y + f)
    }
}

/// A named variation with its weight. Unknown names round-trip through
/// serialization but contribute nothing during rendering (logged once).
public struct Variation: Sendable, Equatable {
    public let name: String
    public let weight: Double
    public var parameters: [String: Double]
    public init(name: String, weight: Double, parameters: [String: Double] = [:]) {
        (self.name, self.weight, self.parameters) = (name, weight, parameters)
    }
}

/// A single IFS transform: affine pre-transform, weighted variations, post-transform.
public struct Xform: Sendable, Equatable {
    public var affine: AffineTransform
    public var postAffine: AffineTransform
    public var weight: Double
    public var color: Double          // [0,1]
    public var colorSpeed: Double     // blend factor (flam3 `color_speed`)
    public var variations: [Variation]
    public var chaos: [Double]?       // nil => uniform
    public var opacity: Double
    public var animate: Double       // 0 => skip rotation (symmetry xforms); default 1.0
    public var padding: Int          // nonzero => this xform is a flam3_align pad slot
    public var wind: SIMD2<Double>   // refangle anchors for log unwrap (interpolation.c:759)

    public init(
        affine: AffineTransform = .identity,
        postAffine: AffineTransform = .identity,
        weight: Double = 1.0,
        color: Double = 0.0,
        colorSpeed: Double = 0.5,
        variations: [Variation] = [],
        chaos: [Double]? = nil,
        opacity: Double = 1.0,
        animate: Double = 1.0,
        padding: Int = 0,
        wind: SIMD2<Double> = .zero
    ) {
        self.affine = affine
        self.postAffine = postAffine
        self.weight = weight
        self.color = color
        self.colorSpeed = colorSpeed
        self.variations = variations
        self.chaos = chaos
        self.opacity = opacity
        self.animate = animate
        self.padding = padding
        self.wind = wind
    }
}

public enum FilterShape: String, Sendable {
    case gaussian
    case box
    case exp
}

/// Color lookup table: 256 RGB entries in [0,1].
public struct Palette: Sendable, Equatable {
    public var colors: [SIMD3<Double>]
    public init(colors: [SIMD3<Double>]) { self.colors = colors }

    /// Black palette (256 entries).
    public static let black = Palette(colors: Array(repeating: SIMD3<Double>(0, 0, 0), count: 256))
}

/// Camera projection parameters.
public struct Camera: Sendable, Equatable {
    public var center: SIMD2<Double>
    public var scale: Double        // pixels per unit
    public var zoom: Double         // additional log-scale zoom (flam3: pixels *= 2^zoom)
    public var rotation: Double     // degrees

    public init(center: SIMD2<Double> = .zero, scale: Double = 250, zoom: Double = 0, rotation: Double = 0) {
        self.center = center
        self.scale = scale
        self.zoom = zoom
        self.rotation = rotation
    }
}

/// Render quality / post-processing parameters.
public struct Quality: Sendable, Equatable {
    public var oversample: Int
    public var samplesPerPixel: Int
    public var filterRadius: Double
    public var filterShape: FilterShape
    public var gamma: Double
    public var gammaThreshold: Double
    public var vibrancy: Double
    public var brightness: Double
    public var estimatorRadius: Double
    public var estimatorMinimum: Double
    public var estimatorCurveRate: Double   // flam3 `estimator_curve`
    /// flam3 `highlight_power` (palettes.c:318-332). `<0` disables the
    /// saturated-highlight anti-shift (the flam3 default and the synthetic
    /// goldens' setting — `-1`). Real ES genomes set `highlight_power="1"`,
    /// which compresses saturated channels back to 255 via HSV desaturation
    /// and redistributes peaks into the upper-mid range. Default `-1` keeps
    /// the synthetic goldens byte-identical (they don't set the attr).
    public var highlightPower: Double
    /// flam3 motion-blur attrs (the `temporal_filter_*` family). Defaults mirror
    /// flam3 (`temporal_samples=1, temporal_filter_type=box,
    /// temporal_filter_width=1.0, temporal_filter_exp=0`).
    public var temporalSamples: Int
    public var temporalFilterType: FilterShape
    public var temporalFilterWidth: Double
    public var temporalFilterExp: Double    // flam3 temporal_filter_exp (default 0; unused for box/gaussian)

    public init(
        oversample: Int = 1,
        samplesPerPixel: Int = 100,
        filterRadius: Double = 0.5,
        filterShape: FilterShape = .gaussian,
        gamma: Double = 2.2,
        gammaThreshold: Double = 0.01,
        vibrancy: Double = 1.0,
        brightness: Double = 4.0,
        estimatorRadius: Double = 0,
        estimatorMinimum: Double = 0,
        estimatorCurveRate: Double = 0.6,
        highlightPower: Double = -1.0,
        temporalSamples: Int = 1,
        temporalFilterType: FilterShape = .box,
        temporalFilterWidth: Double = 1.0,
        temporalFilterExp: Double = 0
    ) {
        self.oversample = oversample
        self.samplesPerPixel = samplesPerPixel
        self.filterRadius = filterRadius
        self.filterShape = filterShape
        self.gamma = gamma
        self.gammaThreshold = gammaThreshold
        self.vibrancy = vibrancy
        self.brightness = brightness
        self.estimatorRadius = estimatorRadius
        self.estimatorMinimum = estimatorMinimum
        self.estimatorCurveRate = estimatorCurveRate
        self.highlightPower = highlightPower
        self.temporalSamples = temporalSamples
        self.temporalFilterType = temporalFilterType
        self.temporalFilterWidth = temporalFilterWidth
        self.temporalFilterExp = temporalFilterExp
    }
}

/// A single flame genome (one animation keyframe when several share a document).
public struct Flame: Sendable, Equatable {
    public var name: String
    public var size: SIMD2<Int>
    public var camera: Camera
    public var quality: Quality
    public var xforms: [Xform]
    public var finalXform: Xform?
    public var palette: Palette
    /// flam3 `hue` attr — palette hue shift; serialized as `hue="…"`. Round-trip only (not consumed by the renderer).
    public var hueShift: Double
    public var time: Double
    public var interpolation: TempInterpolation
    public var interpolationType: MatrixInterpolationType
    public var paletteInterpolation: PaletteInterpolation
    /// flam3 `hue_rotation` attr — per-frame hue rotation; wired into parser/serializer in Task 3, palette blend in Task 9.
    public var hueRotation: Double
    public var hsvRgbPaletteBlend: Double   // flam3 hsv_rgb_palette_blend (LIVE palette mix fraction)

    public init(
        name: String = "",
        size: SIMD2<Int> = SIMD2<Int>(1920, 1080),
        camera: Camera = Camera(),
        quality: Quality = Quality(),
        xforms: [Xform] = [],
        finalXform: Xform? = nil,
        palette: Palette = .black,
        hueShift: Double = 0,
        time: Double = 0,
        interpolation: TempInterpolation = .linear,
        interpolationType: MatrixInterpolationType = .log,
        paletteInterpolation: PaletteInterpolation = .hsvCircular,
        hueRotation: Double = 0,
        hsvRgbPaletteBlend: Double = 0
    ) {
        self.name = name
        self.size = size
        self.camera = camera
        self.quality = quality
        self.xforms = xforms
        self.finalXform = finalXform
        self.palette = palette
        self.hueShift = hueShift
        self.time = time
        self.interpolation = interpolation
        self.interpolationType = interpolationType
        self.paletteInterpolation = paletteInterpolation
        self.hueRotation = hueRotation
        self.hsvRgbPaletteBlend = hsvRgbPaletteBlend
    }
}

/// Errors raised during genome parse / validate.
public enum FlameKitError: Error, Equatable, Sendable {
    case malformedXML(String)
    case invalidAttribute(String, value: String)
    case missingElement(String)
    case degenerateTransform(String)
}
