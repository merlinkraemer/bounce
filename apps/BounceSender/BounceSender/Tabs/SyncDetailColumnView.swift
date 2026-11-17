import SwiftUI
import BounceKit

struct SyncDetailColumnView: View {
    let device: SyncDeviceSummary
    let items: [SyncListItem]
    let stats: SyncLibraryStats
    let peer: BondedPeer?
    let session: SyncSessionStats
    let onForget: () -> Void
    let isBonded: Bool

    @Environment(TransferManager.self) private var transferManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SyncHeaderView(
                device: device,
                onForget: onForget,
                isBonded: isBonded
            )

            Divider()

            if items.isEmpty {
                SyncIdleOverviewView(
                    stats: stats,
                    peer: peer,
                    session: session,
                    authIssue: authIssue,
                    onRetry: retryPublish,
                    canRetry: canRetry
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if let authIssue {
                            SyncAuthIssueNotice(
                                issue: authIssue,
                                onRetry: retryPublish,
                                canRetry: canRetry
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        SyncActivitySummaryBar(device: device)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 4)

                        ForEach(items) { item in
                            SyncListRow(item: item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Auth failures are recorded on the bonded peer, so this survives a
    /// relaunch while the session counters do not.
    private var authIssue: SyncAuthIssue? {
        guard let peer, peer.consecutiveAuthFailures > 0 else { return nil }
        return SyncAuthIssue(
            failureCount: peer.consecutiveAuthFailures,
            lastFailureAt: peer.lastAuthFailureAt
        )
    }

    private var canRetry: Bool {
        switch device.connectionState {
        case .connected, .idle:
            return true
        default:
            return false
        }
    }

    private func retryPublish() {
        transferManager.pushManifestIfConnected(force: true)
    }
}

/// Idle body: persisted library and pairing figures first, session counters
/// last. A grouped form matches the other macOS modals.
private struct SyncIdleOverviewView: View {
    let stats: SyncLibraryStats
    let peer: BondedPeer?
    let session: SyncSessionStats
    let authIssue: SyncAuthIssue?
    let onRetry: () -> Void
    let canRetry: Bool

    var body: some View {
        Form {
            if let authIssue {
                Section {
                    SyncAuthIssueNotice(
                        issue: authIssue,
                        onRetry: onRetry,
                        canRetry: canRetry
                    )
                }
            }

            Section("Library") {
                LabeledContent("Tracks", value: "\(stats.trackCount)")
                LabeledContent("Versions", value: "\(stats.versionCount)")
                if stats.totalBytes > 0 {
                    LabeledContent("Size", value: SyncFormat.bytes(stats.totalBytes))
                }
                if stats.totalDuration > 0 {
                    LabeledContent("Duration", value: SyncFormat.duration(stats.totalDuration))
                }
                LabeledContent("Released", value: "\(stats.releasedCount)")
                if stats.undeliveredVersionCount > 0 {
                    LabeledContent("Waiting to deliver", value: "\(stats.undeliveredVersionCount) versions")
                }
            }

            if let peer {
                Section("Pairing") {
                    LabeledContent("Bonded", value: peer.bondedAt.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Last seen", value: peer.lastSeenAt.formatted(.relative(presentation: .named)))
                }
            }

            SyncSessionActivitySection(session: session)
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)
    }
}

private struct SyncSessionActivitySection: View {
    let session: SyncSessionStats

    var body: some View {
        Section {
            if session.clientRequestCount > 0 {
                LabeledContent("Requests served", value: "\(session.clientRequestCount)")
            }
            if session.totalBytesServed > 0 {
                LabeledContent("Data served", value: SyncFormat.bytes(session.totalBytesServed))
            }
            if session.lastServedResponseBytes > 0 {
                LabeledContent("Last response", value: SyncFormat.bytes(session.lastServedResponseBytes))
            }
            if session.deliveredThisSession > 0 {
                LabeledContent("Files delivered", value: "\(session.deliveredThisSession)")
            }
            if let lastRequestAt = session.lastClientRequestAt {
                LabeledContent("Last request", value: lastRequestAt.formatted(.relative(presentation: .named)))
            }
            if let appVersion = session.appVersion {
                LabeledContent("iPhone app", value: appVersion)
            }
            if !session.hasActivity {
                Text("No sync activity yet this session.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Session Activity")
        } footer: {
            Text("These counters are cleared when Bounce quits; the sections above persist across launches.")
        }
    }
}

private struct SyncAuthIssue: Equatable {
    let failureCount: Int
    let lastFailureAt: Date?
}

/// Explains an auth failure and offers the only retry the sender has:
/// forcing a new manifest at the connected receiver.
private struct SyncAuthIssueNotice: View {
    let issue: SyncAuthIssue
    let onRetry: () -> Void
    let canRetry: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Pairing issue", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)

            Text(explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Try Again", action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canRetry)
                .help(canRetry
                      ? "Publish a fresh manifest to the connected iPhone."
                      : "Open Bounce on the iPhone to connect, then retry.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var explanation: String {
        let attempts = issue.failureCount == 1
            ? "1 failed authentication attempt"
            : "\(issue.failureCount) failed authentication attempts"
        var text = "\(attempts) from this iPhone."
        if let lastFailureAt = issue.lastFailureAt {
            text += " Last \(lastFailureAt.formatted(.relative(presentation: .named)))."
        }
        text += " Open Bounce on the iPhone to pair again if it keeps failing."
        return text
    }
}

/// One-line context above an active transfer list.
private struct SyncActivitySummaryBar: View {
    let device: SyncDeviceSummary

    var body: some View {
        HStack(spacing: 8) {
            if device.queueCount > 0 {
                Text("\(device.queueCount) queued")
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(SyncFormat.bytes(device.queueBytes))
            } else {
                Text("Nothing queued")
            }

            Spacer(minLength: 12)

            if device.historyCount > 0 {
                Text("\(device.historyCount) delivered this session")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

private enum SyncFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

private struct SyncHeaderView: View {
    let device: SyncDeviceSummary
    let onForget: () -> Void
    let isBonded: Bool

    @State private var showForgetConfirm = false

    private var statusPresentation: SyncStatusPresentation {
        SyncStatusMapper.presentation(
            state: device.connectionState,
            isUnpaired: !isBonded,
            isSyncing: device.connectionState == .syncing,
            role: .sender
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Image("iPhone17")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32)
                .opacity(isActive ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusPresentation.color)
                        .frame(width: 7, height: 7)

                    Text(statusPresentation.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    if !isActive, let lastSeenAt = device.lastSeenAt {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(lastSeenAt, format: .relative(presentation: .named))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isBonded {
                Button("Forget This iPhone…") { showForgetConfirm = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .alert("Forget \(device.name)?", isPresented: $showForgetConfirm) {
            Button("Forget", role: .destructive) { onForget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(device.name) will need to pair again before syncing.")
        }
    }

    private var isActive: Bool {
        switch device.connectionState {
        case .connected, .idle, .syncing:
            return true
        default:
            return false
        }
    }
}

private struct SyncListRow: View {
    let item: SyncListItem

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.trackName)
                        .font(.headline)
                        .lineLimit(1)
                }

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(item.sizeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(item.trailingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: BounceConstants.panelCornerRadius))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var rowBackground: some ShapeStyle {
        if isHovered {
            return AnyShapeStyle(Color.primary.opacity(BounceConstants.panelHoverOpacity))
        }
        return AnyShapeStyle(Color.clear)
    }

    private var statusIcon: some View {
        Image(systemName: item.status == .queued ? "clock.badge" : "checkmark.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(item.status == .queued ? Color.orange : Color.green)
            .frame(width: 18, height: 18)
            .padding(.top, 2)
    }
}
