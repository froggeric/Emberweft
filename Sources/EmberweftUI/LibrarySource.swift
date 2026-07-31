import Foundation

/// Provenance of a library entry — a bundled curated genome or a file under a
/// user-chosen directory. Drives the entry's id namespace and grid sectioning.
public enum LibrarySource: Sendable, Hashable {
    /// A genome shipped in the app's curated bundle resource.
    case bundle
    /// A genome discovered under a user-opened directory root.
    case directory(URL)
}
