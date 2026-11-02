import SwiftUI

/// The scoped ember accent (craft item): an amber drawn from the app icon's
/// flame ring, replacing default system blue for the few places selection
/// identity lives — card selection rings + tick, the filter-count capsule,
/// and the drop-target ring. Everything else stays monochrome (branding.md:
/// branding defers to content; the flames are the only color on screen).
///
/// Programmatic (not an asset catalog): the dev bare-executable has no .app
/// bundle, so an xcassets AccentColor would only resolve in `make dist`
/// builds — this way dev and distributed builds render identically. The
/// dynamic NSColor provider is the code equivalent of a light/dark colorset;
/// both variants clear the 3:1 non-text contrast bar (light #C0742A ≈ 3.6:1
/// on white; dark #E09040 ≈ 6.9:1 on a near-black background).
extension Color {
    /// The ember accent, adapting to light/dark appearance.
    static let ember = Color(nsColor: NSColor(name: nil) { appearance in
        // Covers every dark variant (darkAqua, vividDark, high-contrast dark).
        let isDark = appearance.name.rawValue.lowercased().contains("dark")
        return isDark
            ? NSColor(srgbRed: 0.878, green: 0.565, blue: 0.251, alpha: 1)   // #E09040
            : NSColor(srgbRed: 0.753, green: 0.455, blue: 0.165, alpha: 1)   // #C0742A
    })
}
