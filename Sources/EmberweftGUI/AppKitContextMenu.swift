import AppKit
import ObjectiveC
import SwiftUI

/// AppKit-native context menus for grid/list cells (M6.6 UX fix).
///
/// **Why not SwiftUI `.contextMenu`:** inside the LazyVGrid the SwiftUI menu
/// session is torn down whenever the underlying view re-renders — a thumbnail
/// finishing its load, a facet/badge/metadata `@Observable` publish, a selection
/// change. To the user the menu "disappears before there is time to click",
/// worst on multi-level menus (the Add-to-Collection submenu's longer dwell
/// multiplies the chance). This is a known SwiftUI-on-macOS behavior, not a
/// logic bug in the menu content.
///
/// **The fix (industry-proven):** AppKit's responder-chain context menu. A tiny
/// `NSView` overrides `menu(for:)`, the mechanism native macOS apps have used
/// since the beginning — AppKit owns the tracking session, so SwiftUI re-renders
/// cannot cancel it. The menu is built FRESH inside `menu(for:)`, i.e. from a
/// snapshot of state taken at right-click time, so it can also never mutate
/// under the user mid-session. Submenus are plain `NSMenu`s with the same
/// lifetime guarantee.
///
/// **Attachment:** `.overlay(AppKitContextMenu { …build… })`. The host must be
/// ON TOP to win AppKit's top-down hit-test (a `.background` placement loses to
/// the cell's hit-testable SwiftUI content — `.contentShape` + tap gesture —
/// and the menu never activates). `MenuHostView.hitTest` returns nil for every
/// non-context event, so the overlay is transparent to taps, buttons, and the
/// drag-reorder gesture; it claims the hit only for right/ctrl clicks.
///
/// **Actions:** `NSMenuItem`'s target/action needs an NSObject target, so each
/// item owns a `MenuItemAction` box holding a Swift closure. The menu retains
/// its items and the items retain their targets — the closures outlive the
/// session without leaking past it.
struct AppKitContextMenu: NSViewRepresentable {
    let buildMenu: () -> NSMenu

    func makeNSView(context: Context) -> MenuHostView {
        let view = MenuHostView()
        view.buildMenu = buildMenu
        return view
    }

    func updateNSView(_ view: MenuHostView, context: Context) {
        // Keep the closure current (captures may change as cells recycle); it
        // is only INVOKED at right-click time, never during a render pass.
        view.buildMenu = buildMenu
    }
}

/// The host: returns a freshly built menu when AppKit asks for one.
///
/// **Hit-testing (the load-bearing part):** as a `.background` view the host
/// sits under the SwiftUI content, and SwiftUI's gesture system wins the
/// ordinary hit-test for the cell's taps/drags — so by default the host never
/// becomes the event's target and `menu(for:)` is never consulted (the
/// "menus do not activate" symptom). The classic AppKit filter: `hitTest`
/// claims the view ONLY while the current event is a right-click (or
/// ctrl-click, which macOS reports as `leftMouseDown` + `.control` — claimed
/// via `modifierFlags`), and returns nil for everything else so taps, buttons,
/// and the drag-reorder gesture pass straight through to SwiftUI unchanged.
final class MenuHostView: NSView {
    var buildMenu: (() -> NSMenu)?

    private var isContextMenuEvent: Bool {
        guard let event = NSApp.currentEvent else { return false }
        if event.type == .rightMouseDown { return true }
        if event.type == .leftMouseDown, event.modifierFlags.contains(.control) { return true }
        return false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isContextMenuEvent ? self : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = buildMenu?() else { return nil }
        // AppKit's auto-enabling validates items against the responder chain,
        // which knows nothing about our closure-backed targets — it greys items
        // out (e.g. "New Collection…" when the submenu has no siblings). Our
        // items are self-validating snapshots: opt the whole tree (submenus
        // included) out of validation and leave enablement to the explicit
        // `isEnabled` calls at build time.
        func disableAutoenable(_ m: NSMenu) {
            m.autoenablesItems = false
            for item in m.items {
                if let sub = item.submenu { disableAutoenable(sub) }
            }
        }
        disableAutoenable(menu)
        return menu
    }
}

/// Closure-backed target for `NSMenuItem` (retained by its item).
///
/// `fire` DEFERS the handler to the next main run-loop turn: menu actions run
/// in AppKit's event-tracking mode while the menu session is still tearing
/// down, and state mutations / sheet presentations issued in that window can
/// be swallowed (the "New Collection… click does nothing" symptom). NSObject's
/// `perform(_:with:afterDelay: 0)` lands the handler after the session has
/// fully closed — the standard AppKit-menu-to-SwiftUI bridge — with none of
/// the `@Sendable` requirements a `DispatchQueue.main.async` closure would
/// impose under Swift 6 strict concurrency.
final class MenuItemAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() {
        perform(#selector(fireNow), with: nil, afterDelay: 0)
    }
    @objc private func fireNow() { handler() }
}

extension NSMenuItem {
    /// Associated-object key: strongly retains each item's `MenuItemAction`.
    /// `NSMenuItem.target` is a WEAK reference on macOS (the item does not
    /// retain its target — the documented AppKit gotcha), so a closure-box
    /// assigned as `target` deallocates as soon as the menu is built and the
    /// click dispatches into the void (menu items appear disabled under
    /// autoenabling validation against a nil target, and inert once validation
    /// is off). Associating the box to the item gives it the item's own
    /// lifetime — the standard workaround.
    private nonisolated(unsafe) static var actionBoxKey: UInt8 = 0

    /// Closure-action item. `destructive` renders the title in the system
    /// destructive red (the AppKit counterpart of SwiftUI's `.destructive`).
    convenience init(_ title: String,
                     destructive: Bool = false,
                     action: @escaping () -> Void) {
        self.init(title: title, action: #selector(MenuItemAction.fire), keyEquivalent: "")
        let box = MenuItemAction(action)
        self.target = box
        objc_setAssociatedObject(self, &Self.actionBoxKey, box, .OBJC_ASSOCIATION_RETAIN)
        if destructive {
            // Standard macOS pattern for destructive menu rows (e.g. Remove /
            // Delete): red attributed title, matching SwiftUI's role styling.
            self.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed])
        }
    }

    /// Convenience builder: submenu item whose contents are built lazily at
    /// open time (same snapshot semantics as the top-level menu).
    static func submenu(_ title: String, _ children: () -> NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = children()
        return item
    }
}
