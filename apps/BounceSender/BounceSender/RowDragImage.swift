import AppKit
import UniformTypeIdentifiers

/// Cells that render selection-dependent colors should opt out of the
/// selected palette while a drag ghost bitmap is captured.
protocol DragSnapshotPreparable: AnyObject {
    func beginDragSnapshot()
    func endDragSnapshot()
}

/// Renders a drag ghost for a table row whose content lives in an
/// NSHostingView. AppKit's default drag image draws via Core Graphics and
/// can't capture layer-backed SwiftUI content, so we composite a rounded
/// opaque card and a `cacheDisplay` bitmap of the cell ourselves.
@MainActor
enum RowDragImage {
    private static let cornerRadius: CGFloat = 8
    private static let horizontalInset: CGFloat = 4
    private static let verticalInset: CGFloat = 1

    static func make(for cellView: NSTableCellView, tableView: NSTableView) -> NSImage {
        let bounds = cellView.bounds
        let appearance = tableView.effectiveAppearance

        // Suppress selected-state tinting so a selected row's ghost reads the
        // same as an unselected one.
        let preparable = findPreparable(in: cellView)
        preparable?.beginDragSnapshot()

        // Capture the cell content into a backing-store-matched bitmap. Setting
        // the cell's appearance propagates to its NSHostingView so SwiftUI
        // resolves .primary/.secondary for the right mode; a single
        // layoutSubtreeIfNeeded is enough — forcing displayIfNeeded on every
        // subview makes nested materials render opaque and hides the card fill.
        let oldAppearance = cellView.appearance
        cellView.appearance = appearance
        cellView.layoutSubtreeIfNeeded()

        let bitmap = cellView.bitmapImageRepForCachingDisplay(in: bounds)
        if let bitmap {
            appearance.performAsCurrentDrawingAppearance {
                cellView.cacheDisplay(in: bounds, to: bitmap)
            }
        }

        cellView.appearance = oldAppearance
        preparable?.endDragSnapshot()

        // Size the ghost image to the inset rounded card only. A full-cell image
        // with transparent corners still paints as a darker rectangle behind the
        // clipped card during the drag session.
        let insetRect = bounds.insetBy(dx: Self.horizontalInset, dy: Self.verticalInset)
        let cardSize = insetRect.size
        let cardBounds = NSRect(origin: .zero, size: cardSize)
        let path = NSBezierPath(
            roundedRect: cardBounds,
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )

        let image = NSImage(size: cardSize)
        image.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            // Opaque card so the ghost reads as a solid row over the
            // window/desktop. The row's real background is a live material
            // that can't be captured offscreen, so we draw this fill in its
            // place. Outside the rounded path stays clear (no square halo).
            dragFillColor(for: appearance).setFill()
            path.fill()

            if let bitmap {
                NSGraphicsContext.current?.saveGraphicsState()
                path.addClip()
                // Offset so cell-local content lines up with the card crop.
                // Explicit sourceOver: plain draw(in:) can composite with
                // `.copy`, which erases the card fill through transparent
                // row pixels.
                bitmap.draw(
                    in: NSRect(
                        x: -Self.horizontalInset,
                        y: -Self.verticalInset,
                        width: bounds.width,
                        height: bounds.height
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: nil
                )
                NSGraphicsContext.current?.restoreGraphicsState()
            }
        }
        image.unlockFocus()

        return image
    }

    private static func dragFillColor(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(white: 0.28, alpha: 1.0)
            : NSColor(white: 0.92, alpha: 1.0)
    }

    private static func findPreparable(in view: NSView) -> DragSnapshotPreparable? {
        if let preparable = view as? DragSnapshotPreparable {
            return preparable
        }
        for subview in view.subviews {
            if let preparable = findPreparable(in: subview) {
                return preparable
            }
        }
        return nil
    }

    /// Renders one ghost per dragged row and assigns them to the session's
    /// dragging items in order.
    static func apply(
        to session: NSDraggingSession,
        tableView: NSTableView,
        rowIndexes: IndexSet
    ) {
        let images: [NSImage] = rowIndexes.compactMap { row in
            guard let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView else { return nil }
            return make(for: cellView, tableView: tableView)
        }
        guard !images.isEmpty else { return }

        let rowComponents = RowComponents()
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { draggingItem, index, _ in
            let image = images[min(index, images.count - 1)]
            let component = NSDraggingImageComponent(key: .icon)
            component.contents = image
            component.frame = NSRect(origin: .zero, size: image.size)
            // Replace AppKit's default components entirely so a second opaque
            // rect cannot show behind our rounded card.
            draggingItem.imageComponentsProvider = { [component] }
            rowComponents.store(component, frame: draggingItem.draggingFrame, at: index)
        }

        FileDragImageSwapper(session: session, tableView: tableView, rowComponents: rowComponents).start()
    }
}

@MainActor
final class RowComponents {
    private var components: [Int: NSDraggingImageComponent] = [:]
    private var frames: [Int: NSRect] = [:]

    func store(_ component: NSDraggingImageComponent, frame: NSRect, at index: Int) {
        components[index] = component
        frames[index] = frame
    }

    func frame(at index: Int) -> NSRect? {
        frames[index]
    }

    func component(at index: Int) -> NSDraggingImageComponent? {
        components[index]
    }
}

/// Inside the window the dragged rows keep their row ghost; once the cursor
/// leaves the window each item turns into a Finder-style file icon with its
/// filename, and turns back on re-entry.
@MainActor
private final class FileDragImageSwapper {
    private static let iconSide: CGFloat = 48
    private static let labelMaxWidth: CGFloat = 140
    private static let stackOffset: CGFloat = 4

    private let session: NSDraggingSession
    private weak var tableView: NSTableView?
    private let rowComponents: RowComponents
    private var showsFileImages = false
    private var timer: Timer?

    init(session: NSDraggingSession, tableView: NSTableView, rowComponents: RowComponents) {
        self.session = session
        self.tableView = tableView
        self.rowComponents = rowComponents
    }

    func start() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [self] _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0, let window = tableView?.window else {
            timer?.invalidate()
            timer = nil
            return
        }
        let outside = !window.frame.contains(NSEvent.mouseLocation)
        guard outside != showsFileImages else { return }
        showsFileImages = outside
        applyImages(outside: outside)
    }

    private func applyImages(outside: Bool) {
        let rowComponents = rowComponents
        let cursor = tableView.map { $0.convert(NSEvent.mouseLocation.screenToWindow(in: $0.window), from: nil) } ?? .zero
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { draggingItem, index, _ in
            let component: NSDraggingImageComponent
            if outside, let fileComponent = Self.fileComponent(for: draggingItem, index: index) {
                component = fileComponent
                let size = fileComponent.frame.size
                let offset = CGFloat(min(index, 4)) * Self.stackOffset
                draggingItem.draggingFrame = NSRect(
                    x: cursor.x - size.width / 2 + offset,
                    y: cursor.y - size.height / 2 + offset,
                    width: size.width,
                    height: size.height
                )
                fileComponent.frame = NSRect(origin: .zero, size: size)
            } else if let rowComponent = rowComponents.component(at: index), let rowFrame = rowComponents.frame(at: index) {
                component = rowComponent
                draggingItem.draggingFrame = rowFrame
            } else {
                return
            }
            draggingItem.imageComponentsProvider = { [component] }
        }
    }

    private static func fileComponent(for draggingItem: NSDraggingItem, index _: Int) -> NSDraggingImageComponent? {
        guard let pasteboardItem = draggingItem.item as? NSPasteboardItem,
              let urlString = pasteboardItem.string(forType: .fileURL),
              let url = URL(string: urlString)
        else { return nil }

        let image = fileImage(for: url)
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = NSRect(origin: .zero, size: image.size)
        return component
    }

    private static func fileImage(for url: URL) -> NSImage {
        let type = UTType(filenameExtension: url.pathExtension) ?? .audio
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: iconSide, height: iconSide)

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        style.alignment = .center
        let label = NSAttributedString(
            string: url.lastPathComponent,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style
            ]
        )
        let textSize = label.size()
        let labelWidth = min(ceil(textSize.width), labelMaxWidth)
        let pillSize = NSSize(width: labelWidth + 12, height: ceil(textSize.height) + 4)
        let size = NSSize(width: max(iconSide, pillSize.width), height: iconSide + 4 + pillSize.height)

        let image = NSImage(size: size)
        image.lockFocus()
        icon.draw(
            in: NSRect(x: (size.width - iconSide) / 2, y: size.height - iconSide, width: iconSide, height: iconSide)
        )
        let pillRect = NSRect(x: (size.width - pillSize.width) / 2, y: 0, width: pillSize.width, height: pillSize.height)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillSize.height / 2, yRadius: pillSize.height / 2).fill()
        label.draw(in: NSRect(x: pillRect.minX + 6, y: pillRect.minY + 2, width: labelWidth, height: pillSize.height - 4))
        image.unlockFocus()
        return image
    }
}

private extension NSPoint {
    func screenToWindow(in window: NSWindow?) -> NSPoint {
        window?.convertPoint(fromScreen: self) ?? self
    }
}
