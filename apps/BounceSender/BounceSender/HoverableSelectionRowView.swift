import AppKit
import SwiftUI

/// Single source of truth for the tracklist hover/selection fills. Note cards
/// reuse these exact tokens so their normal/active fills cannot drift from the
/// rows they mirror. `hover`/`selection` exist because the AppKit row draws
/// with `NSColor`; the `*Color` variants are the same tokens for SwiftUI.
enum BounceSelectionPalette {
    static let hoverAlpha: CGFloat = 0.04
    static let selectionAlpha: CGFloat = 0.10

    static var hover: NSColor { NSColor.labelColor.withAlphaComponent(hoverAlpha) }
    static var selection: NSColor { NSColor.labelColor.withAlphaComponent(selectionAlpha) }

    static var hoverColor: Color { Color(nsColor: .labelColor).opacity(hoverAlpha) }
    static var selectionColor: Color { Color(nsColor: .labelColor).opacity(selectionAlpha) }
}

final class HoverableSelectionRowView: NSTableRowView {
    private var trackingArea: NSTrackingArea?
    private let hoverHighlightView = NSView(frame: .zero)
    private(set) var isHovered = false
    var hoverDidChange: ((Bool) -> Void)?

    override var isSelected: Bool {
        didSet {
            needsDisplay = true
            updateHoverHighlight(animated: false)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installHoverHighlight()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installHoverHighlight()
    }

    override func layout() {
        super.layout()
        hoverHighlightView.frame = bounds.insetBy(dx: 4, dy: 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverHighlightColor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        syncHoverState()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        syncHoverState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncHoverState()
    }

    override func mouseEntered(with event: NSEvent) {
        requestHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        requestHovered(false)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        drawSelectionHighlight()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        drawSelectionHighlight()
    }

    override var focusRingMaskBounds: NSRect {
        .zero
    }

    override func drawFocusRingMask() {}

    private func drawSelectionHighlight() {
        let isDragImage = NSGraphicsContext.current?.isDrawingToScreen == false

        // RowDragImage draws the solid ghost background; keep bitmap content
        // transparent here. Hover is a separate view so its exit can fade.
        guard !isDragImage, isSelected else { return }

        BounceSelectionPalette.selection.setFill()
        let rect = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        path.fill()
    }

    func syncHoverState() {
        guard let window else {
            requestHovered(false)
            return
        }

        let pointerInWindow = window.mouseLocationOutsideOfEventStream
        let pointerInLocal = convert(pointerInWindow, from: nil)
        requestHovered(bounds.contains(pointerInLocal))
    }

    private func requestHovered(_ hovered: Bool) {
        if hovered {
            guard !isHovered else { return }
            // Enter immediately so quickly crossing rows feels responsive.
            // The previous row's highlight fades independently in
            // `applyHovered(false)`, leaving the intended short trailing tail.
            applyHovered(true)
        } else {
            applyHovered(false)
        }
    }

    private func applyHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
        updateHoverHighlight(animated: !hovered)
        hoverDidChange?(hovered)
    }

    private func installHoverHighlight() {
        hoverHighlightView.wantsLayer = true
        hoverHighlightView.alphaValue = 0
        hoverHighlightView.autoresizingMask = [.width, .height]
        addSubview(hoverHighlightView, positioned: .below, relativeTo: nil)
        updateHoverHighlightColor()
    }

    private func updateHoverHighlightColor() {
        hoverHighlightView.layer?.backgroundColor = BounceSelectionPalette.hover.cgColor
        hoverHighlightView.layer?.cornerRadius = 6
    }

    private func updateHoverHighlight(animated: Bool) {
        let targetOpacity: CGFloat = isHovered && !isSelected ? 1 : 0

        guard animated, targetOpacity == 0 else {
            hoverHighlightView.layer?.removeAllAnimations()
            hoverHighlightView.alphaValue = targetOpacity
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverHighlightView.animator().alphaValue = targetOpacity
        }
    }
}
