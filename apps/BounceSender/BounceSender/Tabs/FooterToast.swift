import SwiftUI

enum FooterToastKind {
    case success
    case info
    case error

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        case .error:   return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: return .green
        case .info:    return .accentColor
        case .error:   return .orange
        }
    }

    var duration: TimeInterval {
        switch self {
        case .success, .info: return 3
        case .error:          return 5
        }
    }
}

struct FooterToast: Identifiable, Equatable {
    let id = UUID()
    let kind: FooterToastKind
    let message: String

    static func == (lhs: FooterToast, rhs: FooterToast) -> Bool { lhs.id == rhs.id }
}

/// Holds the current sidebar-footer toast. One slot — newer replaces older.
/// Ambient confirmations only (import success, sync events, pair events).
/// Undo flows still use the top pill banner, since they need a guaranteed click target.
@Observable
@MainActor
final class FooterToastCenter {
    private(set) var current: FooterToast?
    private var dismissTask: Task<Void, Never>?

    func show(_ kind: FooterToastKind, _ message: String) {
        let toast = FooterToast(kind: kind, message: message)
        current = toast
        dismissTask?.cancel()
        let duration = kind.duration
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.current?.id == toast.id {
                    self.current = nil
                }
            }
        }
    }

    func clear() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }
}
