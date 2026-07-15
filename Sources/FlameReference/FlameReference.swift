//! FlameReference — deterministic CPU fractal-flame renderer (parity oracle,
//! offline renderer, GPU-less fallback).
//!
//! Public API: `ReferenceRenderer`, `ChaosGame`, `DensityEstimation`,
//! `ToneMapping`, `RenderParams`, `RGBA8Image`. Re-exports `FlameKit` so
//! consumers of `FlameReference` get the genome model transitively.
@_exported import FlameKit
