import Foundation

/// A 2D affine transform matching flam3's coefficient convention.
///
/// `coefs = "a b c d e f"` is applied as:
///
/// ```
/// x' = a·x + b·y + c
/// y' = d·x + e·y + f
/// ```
public struct AffineTransform: Sendable, Equatable {
    public var a, b, c, d, e, f: Float
    public init(a: Float, b: Float, c: Float, d: Float, e: Float, f: Float) {
        (self.a, self.b, self.c, self.d, self.e, self.f) = (a, b, c, d, e, f)
    }

    /// Identity transform: maps every point to itself.
    public static let identity = AffineTransform(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0)

    /// Apply the transform to a 2D point using the flam3 convention.
    public func apply(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(a * p.x + b * p.y + c, d * p.x + e * p.y + f)
    }
}

/// A named variation with its weight. Unknown names round-trip through
/// serialization but contribute nothing during rendering (logged once).
public struct Variation: Sendable, Equatable {
    public let name: String
    public let weight: Float
    public init(name: String, weight: Float) { (self.name, self.weight) = (name, weight) }
}

/// A single IFS transform: affine pre-transform, weighted variations, post-transform.
public struct Xform: Sendable, Equatable {
    public var affine: AffineTransform
    public var postAffine: AffineTransform
    public var weight: Float
    public var color: Float          // [0,1]
    public var colorSpeed: Float     // blend factor (flam3 `color_speed`)
    public var variations: [Variation]
    public var chaos: [Float]?       // nil => uniform
    public var opacity: Float

    public init(
        affine: AffineTransform = .identity,
        postAffine: AffineTransform = .identity,
        weight: Float = 1.0,
        color: Float = 0.0,
        colorSpeed: Float = 0.5,
        variations: [Variation] = [],
        chaos: [Float]? = nil,
        opacity: Float = 1.0
    ) {
        self.affine = affine
        self.postAffine = postAffine
        self.weight = weight
        self.color = color
        self.colorSpeed = colorSpeed
        self.variations = variations
        self.chaos = chaos
        self.opacity = opacity
    }
}

public enum FilterShape: String, Sendable {
    case gaussian
    case box
}

/// Color lookup table: 256 RGB entries in [0,1].
public struct Palette: Sendable, Equatable {
    public var colors: [SIMD3<Float>]
    public init(colors: [SIMD3<Float>]) { self.colors = colors }

    /// Black palette (256 entries).
    public static let black = Palette(colors: Array(repeating: SIMD3<Float>(0, 0, 0), count: 256))
}

/// Camera projection parameters.
public struct Camera: Sendable, Equatable {
    public var center: SIMD2<Float>
    public var scale: Float        // pixels per unit
    public var zoom: Float         // additional log-scale zoom (flam3: pixels *= 2^zoom)
    public var rotation: Float     // degrees

    public init(center: SIMD2<Float> = .zero, scale: Float = 250, zoom: Float = 0, rotation: Float = 0) {
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
    public var filterRadius: Float
    public var filterShape: FilterShape
    public var gamma: Float
    public var gammaThreshold: Float
    public var vibrancy: Float
    public var estimatorRadius: Float
    public var estimatorMinimum: Float
    public var estimatorCurveRate: Float   // flam3 `estimator_curve`

    public init(
        oversample: Int = 1,
        samplesPerPixel: Int = 100,
        filterRadius: Float = 0,
        filterShape: FilterShape = .gaussian,
        gamma: Float = 2.2,
        gammaThreshold: Float = 0.01,
        vibrancy: Float = 1.0,
        estimatorRadius: Float = 0,
        estimatorMinimum: Float = 0,
        estimatorCurveRate: Float = 0.6
    ) {
        self.oversample = oversample
        self.samplesPerPixel = samplesPerPixel
        self.filterRadius = filterRadius
        self.filterShape = filterShape
        self.gamma = gamma
        self.gammaThreshold = gammaThreshold
        self.vibrancy = vibrancy
        self.estimatorRadius = estimatorRadius
        self.estimatorMinimum = estimatorMinimum
        self.estimatorCurveRate = estimatorCurveRate
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
    public var hueShift: Float
    public var time: Double

    public init(
        name: String = "",
        size: SIMD2<Int> = SIMD2<Int>(1920, 1080),
        camera: Camera = Camera(),
        quality: Quality = Quality(),
        xforms: [Xform] = [],
        finalXform: Xform? = nil,
        palette: Palette = .black,
        hueShift: Float = 0,
        time: Double = 0
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
    }
}

/// Errors raised during genome parse / validate.
public enum FlameKitError: Error, Equatable, Sendable {
    case malformedXML(String)
    case invalidAttribute(String, value: String)
    case missingElement(String)
    case degenerateTransform(String)
}
