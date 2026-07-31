import Foundation

/// UI-facing scan/load state for the library grid.
public enum LoadState: Sendable, Equatable {
    case loading
    case ready([LibraryEntry])
    case empty
    case failed(String)
}
