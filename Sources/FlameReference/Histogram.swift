import Foundation
import FlameKit

// `RenderParams` and `Histogram` now live in `FlameKit` (RenderTypes.swift),
// lifted there so `FlameRenderer` can depend on `FlameKit` only. This file is
// intentionally retained as the historical home of these types; the
// `@_exported import FlameKit` in FlameReference.swift re-exports them
// unchanged to all `FlameReference` consumers.
