import SwiftUI
import BounceKit

/// Sticky footer at the bottom of the sidebar. Single status surface for
/// toasts, import progress/failures, and sync — priority stack, 44 pt lock.
struct SyncStatusFooter: View {
    let onTap: () -> Void

    @Environment(TransferManager.self) private var transferManager
    @Environment(FooterToastCenter.self) private var toastCenter
    @Environment(ImportCoordinator.self) private var importCoordinator

    @State private var isHovered = false
    @State private var isImportPopoverPresented = false

    /// Locks the footer to the height of the two-line status row so the
    /// toast flip (single line) doesn't shrink the sidebar bottom.
    private static let rowHeight: CGFloat = 44

    private enum DisplayState: Equatable {
        case toast(UUID)
        case importing
        case importFailed
        case sync
    }

    private var displayState: DisplayState {
        if let toast = toastCenter.current {
            return .toast(toast.id)
        }
        if importCoordinator.remainingImportCount > 0 {
            return .importing
        }
        if importCoordinator.hasFailedImports || importCoordinator.hasCancelledImports {
            return .importFailed
        }
        return .sync
    }

    /// Underlying non-toast state used for click routing while a toast is up.
    private var underlyingActionState: DisplayState {
        if importCoordinator.remainingImportCount > 0 {
            return .importing
        }
        if importCoordinator.hasFailedImports || importCoordinator.hasCancelledImports {
            return .importFailed
        }
        return .sync
    }

    var body: some View {
        ZStack {
            switch displayState {
            case .toast:
                if let toast = toastCenter.current {
                    toastRow(toast)
                        .transition(.opacity)
                }
            case .importing:
                importProgressRow
                    .transition(.opacity)
            case .importFailed:
                importFailureRow
                    .transition(.opacity)
            case .sync:
                statusRow
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: displayState)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .background(isHovered ? Color.primary.opacity(BounceConstants.panelHoverOpacity) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: handleTap)
        .help(helpText)
        .disableWindowDrag()
        .popover(isPresented: $isImportPopoverPresented, arrowEdge: .trailing) {
            ImportActivityPopover(
                items: importCoordinator.importActivity,
                onClear: {
                    importCoordinator.clearImportActivity()
                    isImportPopoverPresented = false
                },
                onCancelAll: { importCoordinator.cancelAllImports() },
                onCancel: { importCoordinator.cancelImport(versionID: $0) },
                onRetry: { importCoordinator.retryImport(versionID: $0) }
            )
        }
    }

    // MARK: - Rows

    private var statusRow: some View {
        footerRow(
            icon: { statusIndicator },
            primary: primaryLine,
            secondary: secondaryLine
        )
    }

    private var importProgressRow: some View {
        let total = importCoordinator.importActivity.count
        let remaining = importCoordinator.remainingImportCount
        let done = total - remaining
        let primary = total <= 1 ? "Importing" : "Importing \(done + 1) of \(total)"
        let isIndeterminate = remaining > 0
            && importCoordinator.importActivity.allSatisfy {
                $0.fraction == nil || $0.phase != .converting
            }

        return footerRow(
            icon: {
                ImportProgressRing(
                    fraction: importCoordinator.aggregateImportFraction,
                    isIndeterminate: isIndeterminate
                )
            },
            primary: primary,
            secondary: importCoordinator.activeImportFilename
        )
    }

    private var importFailureRow: some View {
        let failed = importCoordinator.importActivity.filter { $0.phase == .failed }.count
        let cancelled = importCoordinator.importActivity.filter { $0.phase == .cancelled }.count
        let primary: String
        if failed > 0 {
            primary = failed == 1 ? "1 import failed" : "\(failed) imports failed"
        } else {
            primary = cancelled == 1 ? "1 import cancelled" : "\(cancelled) imports cancelled"
        }

        return footerRow(
            icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 16)
            },
            primary: primary,
            secondary: "Click to review"
        )
    }

    private func toastRow(_ toast: FooterToast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: toast.kind.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(toast.kind.tint)
                .frame(width: 14)

            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footerRow<Icon: View>(
        @ViewBuilder icon: () -> Icon,
        primary: String,
        secondary: String?
    ) -> some View {
        HStack(spacing: 10) {
            icon()

            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Sync presentation

    private var isUnpaired: Bool {
        transferManager.bondedPeerStore.peers.isEmpty &&
            transferManager.connectedDeviceID == nil
    }

    private var presentation: SyncStatusPresentation {
        SyncStatusMapper.presentation(
            state: transferManager.connectionState,
            isUnpaired: isUnpaired,
            isSyncing: transferManager.connectionState == .syncing,
            role: .sender
        )
    }

    private var primaryLine: String {
        presentation.label
    }

    private var secondaryLine: String? {
        if isUnpaired { return "Tap to set up" }
        let queued = transferManager.undeliveredVersionIDs.count
        if queued > 0 {
            return "\(queued) queued"
        }
        let bondedFallback = transferManager.bondedPeerStore.peers
            .max(by: { $0.lastSeenAt < $1.lastSeenAt })?.name
        let name = transferManager.connectedDeviceName
            ?? bondedFallback
            ?? "Bounce Receiver"
        switch transferManager.connectionState {
        case .connected, .idle, .syncing:
            return name
        default:
            return nil
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isUnpaired {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 11))
                .foregroundStyle(.tint)
                .frame(width: 14)
        } else {
            Circle()
                .fill(presentation.color)
                .frame(width: 8, height: 8)
        }
    }

    // MARK: - Actions

    private var helpText: String {
        switch displayState {
        case .toast:
            return ""
        case .importing, .importFailed:
            return importCoordinator.importActivityHelpText
        case .sync:
            return "Open sync details"
        }
    }

    private func handleTap() {
        let actionState: DisplayState
        switch displayState {
        case .toast:
            actionState = underlyingActionState
        default:
            actionState = displayState
        }

        switch actionState {
        case .importing, .importFailed:
            isImportPopoverPresented = true
        case .sync, .toast:
            onTap()
        }
    }
}

/// Determinate/indeterminate ring used by the sidebar import progress row.
struct ImportProgressRing: View {
    let fraction: Double
    let isIndeterminate: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
            if isIndeterminate {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: max(0.02, min(fraction, 1)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: fraction)
            }
        }
        .frame(width: 16, height: 16)
    }
}
