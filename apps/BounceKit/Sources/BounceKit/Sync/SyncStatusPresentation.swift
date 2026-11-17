import SwiftUI

/// Canonical user-facing presentation for sync transport status.
/// Use `SyncStatusMapper.presentation(...)` to obtain one.
public struct SyncStatusPresentation: Equatable {
    public let label: String
    public let color: Color
    public let secondaryLabel: String?

    public init(label: String, color: Color, secondaryLabel: String? = nil) {
        self.label = label
        self.color = color
        self.secondaryLabel = secondaryLabel
    }

    public static func == (lhs: SyncStatusPresentation, rhs: SyncStatusPresentation) -> Bool {
        lhs.label == rhs.label && lhs.secondaryLabel == rhs.secondaryLabel
    }
}

public struct SyncStatusMapper {
    /// Returns the canonical presentation for the given sync state.
    ///
    /// - Parameters:
    ///   - state: Current `SyncConnectionState`.
    ///   - isUnpaired: True when no bonded peer exists.
    ///   - isSyncing: True when an active sync round is in progress.
    ///   - autoConnectPaused: True when the receiver has paused auto-sync.
    ///   - failedTransferCount: Non-zero tints the color to orange for
    ///     connected/syncing states to surface transfer issues.
    ///   - authFailureThresholdExceeded: True when auth failures have
    ///     crossed the retry threshold and re-pairing is needed.
    public static func presentation(
        state: SyncConnectionState,
        isUnpaired: Bool,
        isSyncing: Bool = false,
        autoConnectPaused: Bool = false,
        failedTransferCount: Int = 0,
        authFailureThresholdExceeded: Bool = false,
        role: SyncRole = .receiver,
        connectionPath: String? = nil
    ) -> SyncStatusPresentation {
        if isUnpaired {
            return SyncStatusPresentation(label: "Not paired", color: .secondary)
        }

        if authFailureThresholdExceeded {
            return SyncStatusPresentation(
                label: "Auto-sync paused",
                color: .orange,
                secondaryLabel: "Pairing issue"
            )
        }

        if autoConnectPaused {
            return SyncStatusPresentation(label: "Auto-sync paused", color: .orange)
        }

        let activelySyncing = isSyncing || state == .syncing

        if activelySyncing {
            let color: Color = failedTransferCount > 0 ? .orange : .green
            return SyncStatusPresentation(label: "Syncing", color: color)
        }

        switch state {
        case .pairing:
            return SyncStatusPresentation(label: "Pairing", color: .orange)
        case .connected:
            let color: Color = failedTransferCount > 0 ? .orange : .green
            let secondary = connectionPath
            return SyncStatusPresentation(label: "Connected", color: color, secondaryLabel: secondary)
        case .idle, .searching, .found, .disconnected:
            // Mac is purely passive — it can't tell "iPhone is off network"
            // from "iPhone is just backgrounded". When paired but not
            // connected, "Waiting for connection" is honest in either case.
            if role == .sender {
                return SyncStatusPresentation(label: "Waiting for connection", color: .gray)
            }
            if state == .idle {
                return SyncStatusPresentation(label: "Ready", color: .gray)
            }
            return SyncStatusPresentation(label: "Searching", color: .gray)
        case .syncing:
            // Covered by activelySyncing above; kept for exhaustiveness.
            return SyncStatusPresentation(label: "Syncing", color: .green)
        }
    }
}
