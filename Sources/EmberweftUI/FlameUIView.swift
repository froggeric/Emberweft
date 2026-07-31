import SwiftUI
import FlamePlayer

/// SwiftUI bridge for the `@MainActor` `FlameUI` `NSView` (the playback sink).
///
/// `makeNSView` returns the view-model-owned `FlameUI`; `updateNSView` is a
/// deliberate **no-op**. Frames flow `dispatcher → sink.display →
/// metalLayer.contents` entirely outside SwiftUI, so the SwiftUI body is inert
/// during playback — load-bearing for the thin (≈0.3 fps) realtime gate.
@MainActor
public struct FlameUIView: NSViewRepresentable {
    public typealias NSViewType = FlameUI
    private let sinkView: FlameUI

    public init(_ sinkView: FlameUI) { self.sinkView = sinkView }

    public func makeNSView(context: Context) -> FlameUI { sinkView }

    public func updateNSView(_ nsView: FlameUI, context: Context) {
        // No-op: frames arrive through the FrameSink, never via SwiftUI re-render.
    }
}
