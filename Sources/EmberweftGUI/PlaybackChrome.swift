import SwiftUI
import AppKit

/// Shared immersive-mode chrome for both playback windows (the
/// no-distraction-mode finding): hosts the video surface + transport bar and
/// auto-hides the bar in native full screen, with
///   - a bottom-edge hover strip that reveals the bar while it's hidden,
///   - re-hide when the pointer leaves the bar (full screen only),
///   - a ⇧⌘H manual toggle that works anywhere, any mode (reliable restore),
///   - leaving full screen always brings the bar back.
/// Reduce Motion swaps the slide for a plain opacity fade.
///
/// Full-screen state is detected per-window: `willEnterFullScreenNotification`
/// / `didExitFullScreenNotification` filtered by the hosting `NSWindow`
/// (captured via an underlay `NSView`), so one window going full screen does
/// not hide the other windows' bars.
struct ImmersivePlaybackChrome<Surface: View, Bar: View>: View {
    @ViewBuilder private var surface: () -> Surface
    @ViewBuilder private var bar: () -> Bar

    @State private var barHidden = false
    @State private var fullScreen = false
    @State private var hostWindow: NSWindow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(@ViewBuilder surface: @escaping () -> Surface,
         @ViewBuilder bar: @escaping () -> Bar) {
        self.surface = surface
        self.bar = bar
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                surface()
                if !barHidden {
                    bar()
                        // In full screen the bar follows QuickTime rules: leave
                        // the bar's zone ⇒ it goes away again. Outside full
                        // screen only ⇧⌘H hides it.
                        .onHover { over in
                            if fullScreen && !over { barHidden = true }
                        }
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: barHidden)

            // Reveal strip: active ONLY while the bar is hidden, so it never
            // competes with the bar or blocks surface interaction elsewhere.
            if barHidden {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 36)
                    .contentShape(Rectangle())
                    .onHover { over in if over { barHidden = false } }
                    .accessibilityHidden(true)
            }
        }
        .background(WindowCapture(window: $hostWindow))
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.willEnterFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow else { return }
            fullScreen = true
            barHidden = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow else { return }
            fullScreen = false
            barHidden = false
        }
        // Reliable restore + non-full-screen hide: ⇧⌘H toggles anywhere.
        .background {
            Button("Hide or Show Controls") { barHidden.toggle() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .hidden()
        }
    }
}

/// Captures the hosting `NSWindow` into a binding (identity for the
/// full-screen notifications). A zero-size underlay `NSView` whose
/// `viewDidMoveToWindow` fires at mount and window changes.
private struct WindowCapture: NSViewRepresentable {
    @Binding var window: NSWindow?

    final class CaptureView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            onWindow?(self.window)
        }
    }

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onWindow = { window = $0 }
        return v
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {}
}
