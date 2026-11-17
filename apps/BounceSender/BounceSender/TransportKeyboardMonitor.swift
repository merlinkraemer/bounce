import SwiftUI
import AppKit

// MARK: - Keyboard monitor

struct TransportKeyboardMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onTogglePlayback: () -> Void
    let onSkipBackward: () -> Void
    let onSkipForward: () -> Void
    let onAllTracks: () -> Void
    let onAddNote: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.owner = view
        context.coordinator.update(
            isEnabled: isEnabled,
            onTogglePlayback: onTogglePlayback,
            onSkipBackward: onSkipBackward,
            onSkipForward: onSkipForward,
            onAllTracks: onAllTracks,
            onAddNote: onAddNote,
            onEscape: onEscape
        )
        context.coordinator.installMonitorIfNeeded()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.owner = nsView
        context.coordinator.update(
            isEnabled: isEnabled,
            onTogglePlayback: onTogglePlayback,
            onSkipBackward: onSkipBackward,
            onSkipForward: onSkipForward,
            onAllTracks: onAllTracks,
            onAddNote: onAddNote,
            onEscape: onEscape
        )
        context.coordinator.installMonitorIfNeeded()
    }

    final class Coordinator {
        weak var owner: NSView?
        private var keyMonitor: Any?
        private var isEnabled = false
        private var onTogglePlayback: (() -> Void)?
        private var onSkipBackward: (() -> Void)?
        private var onSkipForward: (() -> Void)?
        private var onAllTracks: (() -> Void)?
        private var onAddNote: (() -> Void)?
        private var onEscape: (() -> Void)?

        func update(
            isEnabled: Bool,
            onTogglePlayback: @escaping () -> Void,
            onSkipBackward: @escaping () -> Void,
            onSkipForward: @escaping () -> Void,
            onAllTracks: @escaping () -> Void,
            onAddNote: @escaping () -> Void,
            onEscape: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.onTogglePlayback = onTogglePlayback
            self.onSkipBackward = onSkipBackward
            self.onSkipForward = onSkipForward
            self.onAllTracks = onAllTracks
            self.onAddNote = onAddNote
            self.onEscape = onEscape
        }

        func installMonitorIfNeeded() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window = owner?.window, window.isKeyWindow, NSApp.keyWindow === window else { return false }
            guard !hasBlockingModifierFlags(event.modifierFlags) else { return false }

            if event.keyCode == 53 {
                // Editors own Escape first: a focused inline note editor or
                // rename field must receive `cancelOperation:` instead of the
                // global clear. Popovers are separate key windows, so the
                // window guard above already lets them handle Escape natively.
                guard !isTextInputFocused(in: window) else { return false }
                onEscape?()
                return true
            }

            guard !isTextInputFocused(in: window) else { return false }

            switch event.charactersIgnoringModifiers {
            case "1": onAllTracks?(); return true
            case "n", "N": onAddNote?(); return true
            default: break
            }

            guard isEnabled else { return false }

            switch event.keyCode {
            case 49:
                onTogglePlayback?()
                return true
            case 123:
                onSkipBackward?()
                return true
            case 124:
                onSkipForward?()
                return true
            default:
                return false
            }
        }

        private func hasBlockingModifierFlags(_ flags: NSEvent.ModifierFlags) -> Bool {
            !flags.intersection([.command, .control, .option]).isEmpty
        }

        private func isTextInputFocused(in window: NSWindow) -> Bool {
            if window.firstResponder is NSText {
                return true
            }

            var responder = window.firstResponder?.nextResponder
            while let current = responder {
                if current is NSTextField || current is NSTextView || current is NSSearchField {
                    return true
                }
                responder = current.nextResponder
            }

            return false
        }

        deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }
    }
}
