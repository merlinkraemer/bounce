import SwiftUI
import AppKit

/// Bridge to NSVisualEffectView for native macOS material effects.
/// Currently used by the catalogue's `ColumnEdgeFade` for in-window edge blur
/// (`underPageBackground` + `withinWindow`), and kept generic for other
/// material surfaces that need AppKit-only blending modes or state.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

// MARK: - Column background system

/// Semantic role for a column in the multi-column layout.
///
/// Option A (Finder-exact): All columns use opaque `controlBackgroundColor`.
/// The sidebar role is kept as a semantic label so we can re-introduce a subtle
/// material later (Option B) without changing call sites.
enum ColumnRole {
    case sidebar
    case content
    case detail
}

private struct ColumnBackgroundModifier: ViewModifier {
    let role: ColumnRole

    func body(content: Content) -> some View {
        switch role {
        case .sidebar:
            // Keep the columns on one opaque surface. The native
            // NavigationSplitView divider is the only intended seam; the
            // under-page tonal step reads as a second border in this layout.
            content.background(Color(nsColor: .controlBackgroundColor))
        case .content, .detail:
            content.background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

extension View {
    /// Applies the standard column background for the given role.
    func columnBackground(_ role: ColumnRole) -> some View {
        modifier(ColumnBackgroundModifier(role: role))
    }

    /// Prevents the area from acting as a window-drag handle.
    /// SwiftUI columns/inspectors with non-opaque hit-testing inherit
    /// the parent window's drag region; this swaps in an NSView that
    /// returns `mouseDownCanMoveWindow = false`. Prefer also overriding
    /// `mouseDownCanMoveWindow` on interactive AppKit controls in the area.
    func disableWindowDrag() -> some View {
        background(WindowDragBlocker())
    }
}

private struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BlockingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class BlockingView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Background-only: never steal clicks from foreground controls
            // (e.g. the sidebar + menu), but still mark the region non-movable
            // when AppKit walks the ancestry for window-drag eligibility.
            nil
        }
    }
}
