import AppKit
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
/// **Attachment:** `.background(AppKitContextMenu { …build… })`. A background
/// view keeps the layout untouched and sits under the SwiftUI content; right
/// clicks (unhandled by SwiftUI text/images) fall through to it. Left-click
/// behavior (cell taps, buttons, the custom drag gesture) is unaffected.
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
final class MenuHostView: NSView {
    var buildMenu: (() -> NSMenu)?

    override func menu(for event: NSEvent) -> NSMenu? {
        buildMenu?()
    }
}

/// Closure-backed target for `NSMenuItem` (retained by its item).
final class MenuItemAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

extension NSMenuItem {
    /// Closure-action item. `destructive` renders the title in the system
    /// destructive red (the AppKit counterpart of SwiftUI's `.destructive`).
    convenience init(_ title: String,
                     destructive: Bool = false,
                     action: @escaping () -> Void) {
        self.init(title: title, action: #selector(MenuItemAction.fire), keyEquivalent: "")
        self.target = MenuItemAction(action)
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
