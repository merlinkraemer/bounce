import SwiftUI
import AppKit

/// SwiftUI wrapper for native NSPopover with no entrance animation.
/// Use via `.background(NativePopoverHost(...))` to anchor to the host view.
struct NativePopoverHost<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var preferredEdge: NSRectEdge = .minY
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(isPresented: isPresented, anchor: nsView, preferredEdge: preferredEdge, content: content())
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool
        private var popover: NSPopover?
        private var hostingController: NSHostingController<Content>?

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func update(isPresented: Bool, anchor: NSView, preferredEdge: NSRectEdge, content: Content) {
            if isPresented {
                if let popover, popover.isShown {
                    hostingController?.rootView = content
                    return
                }
                let host = NSHostingController(rootView: content)
                let popover = NSPopover()
                popover.behavior = .transient
                popover.contentViewController = host
                popover.delegate = self
                self.popover = popover
                self.hostingController = host
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
            } else {
                popover?.performClose(nil)
                popover = nil
                hostingController = nil
            }
        }

        func popoverDidClose(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.popover = nil
                self.hostingController = nil
                if self.isPresented { self.isPresented = false }
            }
        }
    }
}
