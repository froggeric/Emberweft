import Foundation
import FlameKit
import FlamePlayer

/// `SheepProvider` that serves one `Flame` for every index — loop-only playback
/// of a single clicked genome. Backs the click-to-play vertical slice.
public struct SingleFlameProvider: SheepProvider {
    public let flame: Flame

    public init(_ flame: Flame) { self.flame = flame }

    public func sheep(at index: Int) async -> Flame { flame }
}
