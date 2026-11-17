import SwiftUI
import BounceKit

struct ConnectionStatusDot: View {
    @Environment(DownloadManager.self) private var downloadManager

    var body: some View {
        let presentation = downloadManager.syncStatusPresentation

        Circle()
            .fill(presentation.color)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            }
            .accessibilityLabel(presentation.label)
    }
}

/// Fixed-size toolbar icon so sync status updates don't reflow the navigation title.
struct LibraryToolbarSyncButton: View {
    @Environment(DownloadManager.self) private var downloadManager

    private var isUnpaired: Bool {
        downloadManager.bondedPeerStore.peers.isEmpty
    }

    // Debounced snapshot of the sync presentation. Rendering the live value
    // rebuilds this Liquid Glass toolbar item on every sync start/stop (10s
    // poll cadence) — when that lands mid push/pop transition, the iOS 26/27
    // nav bar can trap layout and freeze the app (0x8BADF00D watchdog logs on
    // device). Coalescing to one update per quiet window keeps bar mutations
    // off the transition path; the dot/label lag <1s, which is imperceptible.
    @State private var status: SyncStatusPresentation?
    @State private var updateTask: Task<Void, Never>?

    var body: some View {
        let _ = DebugLog.log("SyncButton body")
        let presentation = status ?? downloadManager.syncStatusPresentation

        ZStack(alignment: .topTrailing) {
            Image(systemName: isUnpaired ? "link" : "arrow.triangle.2.circlepath")
                .font(.body)
                .foregroundStyle(isUnpaired ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: 28, height: 28)

            if !isUnpaired {
                Circle()
                    .fill(presentation.color)
                    .frame(width: 8, height: 8)
                    .overlay {
                        Circle()
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                    }
                    .accessibilityLabel(presentation.label)
                    .offset(x: 4, y: -2)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityLabel(isUnpaired ? "Pair" : presentation.label)
        .animation(nil, value: presentation.label)
        .onAppear { status = downloadManager.syncStatusPresentation }
        .onChange(of: downloadManager.syncStatusPresentation) { _, new in
            scheduleStatusUpdate(new)
        }
        .onDisappear { updateTask?.cancel() }
    }

    private func scheduleStatusUpdate(_ new: SyncStatusPresentation) {
        updateTask?.cancel()
        updateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            status = new
        }
    }
}
