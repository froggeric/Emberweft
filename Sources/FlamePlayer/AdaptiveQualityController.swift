import Foundation

// AdaptiveQualityController — M3 deterministic adaptive-quality gate.
//
// A PURE value type that maps `(measuredFps, thermalState, currentBudget)` to a
// new renderer `samplesPerPixel` budget via hysteretic feedback. The "iteration
// budget" IS `RenderParams.samplesPerPixel` (the per-pixel sample count handed
// to the Metal chaos-game renderer): higher = more quality + more GPU work, so
// when measured fps drops below target we shed work, and when it exceeds target
// we reclaim quality headroom.
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │ Determinism contract (LOAD-BEARING — M3 gate)                           │
// ├─────────────────────────────────────────────────────────────────────────┤
// │ • NO hidden state. The previous budget is an INPUT (`currentBudget`),   │
// │   not stored on the type. Identical inputs ALWAYS yield identical       │
// │   output — the controller is a pure function.                           │
// │ • NO `Date()`, NO RNG, NO global reads. `thermalState` is passed in     │
// │   (the caller samples `ProcessInfo.processInfo.thermalState`); the      │
// │   controller never touches the process singleton itself.                │
// │ • `Sendable + Equatable` value type — trivial Swift 6 concurrency.      │
// │ • Real thermal-throttle behavior is verified manually and deferred to   │
// │   M4; this controller's job is to be the deterministic decision gate.   │
// └─────────────────────────────────────────────────────────────────────────┘
//
// Hysteresis design (the point — prevent oscillation from fps jitter):
//
//   ┌───────────── step UP (× upFactor) ─────────────┐
//   │                 targetFps + deadbandFps         │  ← upper threshold (33)
//   │  ════════════════ DEADBAND (no change) ═══════  │  27 .. 33 @ target 30
//   │                 targetFps - deadbandFps         │  ← lower threshold (27)
//   └───────────── step DOWN (× downFactor) ─────────┘
//
// Fps jitter that stays inside `[target-deadband, target+deadband]` leaves the
// budget untouched. Only a sustained excursion past a threshold moves it: below
// the lower threshold the budget is multiplied by `downFactor` (shedding work),
// above the upper threshold by `upFactor` (reclaiming quality). A single
// excursion does NOT auto-revert — recovery requires a sustained
// above-threshold signal, which is what makes this hysteretic rather than a
// bang-bang controller.
//
// `.critical` thermal overrides everything and forces the budget to a floor
// (`criticalFloorSamplesPerPixel`) regardless of fps — the device is too hot,
// so we drop to minimum viable quality. `.fair` / `.serious` are treated like
// `.nominal` (fps-driven); only `.critical` forces the floor. Real per-tier
// thermal curving is an M4 concern.

/// A pure, deterministic adaptive-quality controller.
public struct AdaptiveQualityController: Sendable, Equatable {

    /// Tunable thresholds + bounds. All inputs to the decision; the controller
    /// holds no state beyond this immutable config.
    public struct Config: Sendable, Equatable {

        /// Target presentation rate. fps inside the deadband around this is
        /// considered "on pace" → no budget change.
        public let targetFps: Double

        /// Half-width of the no-op deadband. Step DOWN below
        /// `targetFps - deadbandFps`, UP above `targetFps + deadbandFps`.
        public let deadbandFps: Double

        /// Multiplier applied to the budget when stepping DOWN (work-shedding).
        /// Must be in `(0, 1)`.
        public let downFactor: Double

        /// Multiplier applied to the budget when stepping UP (quality recovery).
        /// Must be `> 1`.
        public let upFactor: Double

        /// Inclusive lower bound on the emitted budget.
        public let minSamplesPerPixel: Int

        /// Inclusive upper bound on the emitted budget.
        public let maxSamplesPerPixel: Int

        /// Forced budget when `thermalState == .critical`, regardless of fps.
        /// Clamped into `[minSamplesPerPixel, maxSamplesPerPixel]`.
        public let criticalFloorSamplesPerPixel: Int

        /// Construct a config. Preconditions guard the hysteresis invariants.
        public init(
            targetFps: Double = 30,
            deadbandFps: Double = 3,
            downFactor: Double = 0.5,
            upFactor: Double = 2.0,
            minSamplesPerPixel: Int = 2,
            maxSamplesPerPixel: Int = 512,
            criticalFloorSamplesPerPixel: Int = 4
        ) {
            precondition(targetFps > 0, "targetFps must be > 0")
            precondition(deadbandFps >= 0, "deadbandFps must be >= 0")
            precondition(downFactor > 0 && downFactor < 1, "downFactor must be in (0, 1)")
            precondition(upFactor > 1, "upFactor must be > 1")
            precondition(minSamplesPerPixel >= 1, "minSamplesPerPixel must be >= 1")
            precondition(maxSamplesPerPixel >= minSamplesPerPixel,
                         "maxSamplesPerPixel must be >= minSamplesPerPixel")
            precondition(criticalFloorSamplesPerPixel >= minSamplesPerPixel
                         && criticalFloorSamplesPerPixel <= maxSamplesPerPixel,
                         "criticalFloorSamplesPerPixel must be within [min, max]")
            self.targetFps = targetFps
            self.deadbandFps = deadbandFps
            self.downFactor = downFactor
            self.upFactor = upFactor
            self.minSamplesPerPixel = minSamplesPerPixel
            self.maxSamplesPerPixel = maxSamplesPerPixel
            self.criticalFloorSamplesPerPixel = criticalFloorSamplesPerPixel
        }
    }

    /// Immutable thresholds. The controller holds NO other state.
    public let config: Config

    /// Construct with a config (defaults to `.default`).
    public init(config: Config = .default) {
        self.config = config
    }

    /// Compute the next `samplesPerPixel` budget from the measured signal.
    ///
    /// - Parameters:
    ///   - measuredFps: The most recent measured presentation rate (fps).
    ///   - thermalState: The system thermal state at the same instant. The
    ///     caller samples `ProcessInfo.processInfo.thermalState`; the controller
    ///     never reads the singleton, preserving determinism.
    ///   - currentBudget: The renderer's current `samplesPerPixel` (the previous
    ///     output of this function, or the seed budget).
    /// - Returns: The new `samplesPerPixel`, clamped to
    ///   `[minSamplesPerPixel, maxSamplesPerPixel]`.
    public func step(
        measuredFps: Double,
        thermalState: ProcessInfo.ThermalState,
        currentBudget: Int
    ) -> Int {
        let c = config

        // .critical thermal forces the floor regardless of fps.
        if thermalState == .critical {
            return c.criticalFloorSamplesPerPixel
        }

        // Hysteretic fps gate. Boundaries are INCLUSIVE to the deadband so a
        // measurement landing exactly on a threshold doesn't jitter the budget.
        let next: Int
        if measuredFps < c.targetFps - c.deadbandFps {
            // Below the lower threshold → shed work (round half away from zero
            // for a deterministic, symmetric rounding rule).
            next = scaled(currentBudget, by: c.downFactor)
        } else if measuredFps > c.targetFps + c.deadbandFps {
            // Above the upper threshold → reclaim quality.
            next = scaled(currentBudget, by: c.upFactor)
        } else {
            // Deadband: unchanged.
            next = currentBudget
        }

        // Always clamp so the invariant "budget in [min, max]" holds even when
        // the caller seeded an out-of-range currentBudget.
        return min(max(next, c.minSamplesPerPixel), c.maxSamplesPerPixel)
    }

    /// Deterministic budget scaling: round half away from zero.
    private func scaled(_ budget: Int, by factor: Double) -> Int {
        Int((Double(budget) * factor).rounded(.toNearestOrAwayFromZero))
    }
}

extension AdaptiveQualityController.Config {
    /// Defaults: target 30 fps, ±3 fps deadband (step down < 27, up > 33),
    /// halve on underperformance, double on headroom, budget in [2, 512],
    /// critical-thermal floor of 4.
    public static let `default` = AdaptiveQualityController.Config()
}
