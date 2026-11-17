import SwiftUI
import UIKit
import SwiftData
import BounceKit
import OSLog

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(UploadQueue.self) private var uploadQueue
    @Environment(iOSImportCoordinator.self) private var importCoordinator

    @AppStorage("defaultArtistName") private var defaultArtistName = ""
    @AppStorage(BouncePreferenceKey.showSetsTab) private var showRecordings = BouncePreferenceDefault.showSetsTab

    @State private var showImportPicker = false

    private var reviewGroupBinding: Binding<ImportPlanGroup?> {
        Binding(
            get: { importCoordinator.reviewGroup },
            set: { importCoordinator.reviewGroup = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                importSection
                librarySection
                defaultArtistSection
                aboutSection
                DevSettingsSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showImportPicker) {
                AudioDocumentPicker { urls in
                    Task {
                        guard let url = urls.first else { return }
                        await importCoordinator.beginImportReview(for: url, context: modelContext)
                    }
                }
            }
        }
        .sheet(item: reviewGroupBinding) { group in
            iOSImportReviewSheet(
                group: group,
                availableTracks: importCoordinator.reviewAvailableTracks,
                onConfirm: { confirmedGroup in
                    Task {
                        await importCoordinator.confirmImport(group: confirmedGroup, context: modelContext)
                        uploadQueue.drainQueue()
                    }
                },
                onCancel: {
                    importCoordinator.cancelImport()
                }
            )
        }
    }

    // MARK: - Import

    private var importSection: some View {
        Section {
            Button {
                showImportPicker = true
            } label: {
                Label("Import Audio", systemImage: "square.and.arrow.down")
            }
            .disabled(importCoordinator.isImporting)

            if importCoordinator.isImporting {
                ProgressView("Importing…")
            }

            if let importError = importCoordinator.importError, !importError.isEmpty {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        Section("Library") {
            Toggle(RecordingsCopy.settingsToggle, isOn: $showRecordings)
        }
    }

    // MARK: - Default Artist

    private var defaultArtistSection: some View {
        Section("Default Artist") {
            TextField("Default artist", text: $defaultArtistName)
                .textInputAutocapitalization(.words)

            Button {
                applyDefaultArtistToUnknownTracks()
            } label: {
                Label("Apply to unknown artists", systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(defaultArtistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Bounce")
            LabeledContent("Version", value: appVersion)
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    private func applyDefaultArtistToUnknownTracks() {
        let trimmed = defaultArtistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let descriptor = FetchDescriptor<Track>()
        guard let tracks = try? modelContext.fetch(descriptor) else { return }

        for track in tracks where shouldApplyDefaultArtist(to: track.artist) {
            track.artist = trimmed
            track.updatedAt = .now
        }

        try? modelContext.save()
    }

    private func shouldApplyDefaultArtist(to artist: String) -> Bool {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let normalized = trimmed.lowercased()
        return normalized == "unknown" || normalized == "unknown artist"
    }
}

// MARK: - Sync Detail Subpage

/// Exposed so LibraryView can present this directly when the user taps the
/// header sync indicator — avoids routing through the full Settings screen.
struct SyncDetailView: View {
    @Environment(DownloadManager.self) private var downloadManager
    @AppStorage(BouncePreferenceKey.receiverDeviceName) private var deviceNameOverride = ""
    @AppStorage("autoDownloadSyncedTracks") private var autoDownloadSyncedTracks = false
    @Environment(UploadQueue.self) private var uploadQueue
    @Query private var allTracks: [Track]
    @Query private var allVersions: [Version]
    @Query private var allPlaylists: [Playlist]
    @Query private var allNotes: [Note]

    private var playlistsCount: Int {
        allPlaylists.filter { !$0.isSoftDeleted }.count
    }

    private var releasesCount: Int {
        allTracks.filter(\.isReleased).count
    }

    private var textNotesCount: Int {
        allNotes.filter { !$0.isSoftDeleted && $0.type == .text }.count
    }

    private var voiceNotesCount: Int {
        allNotes.filter { !$0.isSoftDeleted && $0.type == .voice }.count
    }

    @State private var pairTarget: DiscoveredPeer? = nil
    @State private var pendingNonce: Data? = nil
    @State private var pairError: String? = nil
    @State private var isPairing = false
    @State private var peerToForget: BondedPeer? = nil
    @State private var showForgetAlert = false

    var body: some View {
        List {
            if isUnpaired {
                onboardingSection
                availableSection
            } else {
                pairedMacSection
                authFailureSection
                syncActionsSection
            }
            deviceNameSection
            downloadsSection
            storageSection
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Force a browse + connect attempt every time this screen
            // appears. If the Mac has unilaterally forgotten this device
            // (e.g. user tapped Forget on the desktop), the resulting auth
            // request will hit the 403/forgotten path and the bond will
            // be cleared on this side too — surfacing the Mac as an
            // available device again instead of leaving us stuck on a
            // stale "paired" state with nothing to do. For unpaired users this
            // is also what starts discovery (and the Local Network prompt).
            downloadManager.transport.beginDiscovery()
        }
        .sheet(item: $pairTarget) { peer in
            if let pendingNonce {
                PairWaitingSheet(
                    peer: peer,
                    nonce: pendingNonce,
                    isPairing: $isPairing,
                    errorMessage: $pairError,
                    onCancel: cancelPair
                )
            }
        }
        .alert("Forget Device?", isPresented: $showForgetAlert) {
            Button("Cancel", role: .cancel) {
                peerToForget = nil
            }
            Button("Forget", role: .destructive) {
                if let peer = peerToForget {
                    downloadManager.forgetPeer(peer.id)
                }
                peerToForget = nil
            }
        } message: {
            Text("This will remove \(peerToForget?.name ?? "this device") from trusted devices and stop syncing.")
        }
    }

    // MARK: - State

    private func cancelPair() {
        pairTarget = nil
        pendingNonce = nil
        isPairing = false
        pairError = nil
    }

    private var isUnpaired: Bool {
        downloadManager.bondedPeerStore.peers.isEmpty
    }

    private var connectionText: String {
        downloadManager.syncStatusPresentation.label
    }

    private var connectionPathText: String? {
        downloadManager.syncStatusPresentation.secondaryLabel
    }

    // MARK: - Onboarding

    private var onboardingSection: some View {
        Section {
            EmptyStateBlock(
                symbolName: "laptopcomputer.and.iphone",
                symbolSize: 36,
                title: "Pair with your Mac",
                description: "Bounce syncs over your local network. Use the same Wi‑Fi, or plug in via USB and enable Personal Hotspot on your iPhone.",
                maxContentWidth: 320
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Paired Mac

    @ViewBuilder
    private var pairedMacSection: some View {
        if let peer = downloadManager.bondedPeerStore.peers.first {
            Section("Mac") {
                NavigationLink {
                    SyncLogView()
                } label: {
                    HStack(spacing: 12) {
                        ConnectionStatusDot()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(for: peer))
                                .font(.body)
                            Text(connectionText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let connectionPathText {
                                Text(connectionPathText)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if downloadManager.isSyncing {
                            ProgressView()
                                .scaleEffect(0.75)
                        }
                    }
                }

                Toggle("Pause auto-sync", isOn: pauseBinding)

                Button(role: .destructive) {
                    peerToForget = peer
                    showForgetAlert = true
                } label: {
                    Text("Forget Mac")
                }
            }
        }
    }

    private func displayName(for peer: BondedPeer) -> String {
        if let connectedDeviceName = downloadManager.connectedDeviceName, !connectedDeviceName.isEmpty {
            return connectedDeviceName
        }
        return peer.name
    }

    // MARK: - Available

    @ViewBuilder
    private var availableSection: some View {
        let unbonded = downloadManager.discoveredPeers.filter {
            !downloadManager.bondedPeerStore.contains(id: $0.id)
        }
        Section {
            if unbonded.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.85)
                    Text("Searching for Macs")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ForEach(unbonded) { peer in
                    Button {
                        startPair(with: peer)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text(peer.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            if pairTarget?.id == peer.id && isPairing {
                                ProgressView()
                                    .scaleEffect(0.75)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Available Macs")
        } footer: {
            Text("Open Bounce on your Mac, then select it here.")
        }
        Section {
            GetMacAppHint(isMacFound: !unbonded.isEmpty)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    // MARK: - Actions

    @ViewBuilder
    private var syncActionsSection: some View {
        if shouldShowSyncActions {
            Section {
                Button {
                    Task {
                        await downloadManager.userRequestedSyncNow()
                        uploadQueue.drainQueue()
                    }
                } label: {
                    Label("Try Sync Again", systemImage: "arrow.clockwise")
                }

                if let uploadQueueText {
                    Text(uploadQueueText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let syncError = downloadManager.lastSyncError, !syncError.isEmpty {
                    Text(syncError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var shouldShowSyncActions: Bool {
        let hasQueueOrErrors =
            uploadQueue.pendingCount > 0 ||
            uploadQueue.failedCount > 0 ||
            uploadQueue.uploadingCount > 0 ||
            downloadManager.failedTransferCount > 0 ||
            (downloadManager.lastSyncError?.isEmpty == false)

        if hasQueueOrErrors { return true }

        // Offline / searching: always offer a manual retry when paired.
        switch downloadManager.connectionState {
        case .idle, .searching, .found, .disconnected:
            return true
        case .connected, .syncing, .pairing:
            return false
        }
    }

    private var uploadQueueText: String? {
        let parts = [
            uploadQueue.uploadingCount > 0 ? "\(uploadQueue.uploadingCount) uploading" : nil,
            uploadQueue.pendingCount > 0 ? "\(uploadQueue.pendingCount) queued" : nil,
            uploadQueue.failedCount > 0 ? "\(uploadQueue.failedCount) failed" : nil
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    // MARK: - Device Name

    private var deviceNameSection: some View {
        Section("Device Name") {
            TextField("Device name", text: $deviceNameOverride, prompt: Text(DeviceModelName.current(systemName: UIDevice.current.name)))
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
        }
    }

    // MARK: - Downloads

    private var downloadsSection: some View {
        Section {
            Toggle("Automatically download synced tracks", isOn: $autoDownloadSyncedTracks)
                .onChange(of: autoDownloadSyncedTracks) { _, enabled in
                    guard enabled else { return }
                    Task { await downloadManager.syncNow() }
                }
        } header: {
            Text("Downloads")
        } footer: {
            Text("When enabled, audio received from the paired Mac is stored on this iPhone automatically.")
        }
    }

    // MARK: - Storage

    private var totalAudioBytes: Int64 {
        allVersions.reduce(into: Int64(0)) { sum, v in sum += v.fileSize }
    }

    private var formattedAudioSize: String {
        ByteCountFormatter.string(fromByteCount: totalAudioBytes, countStyle: .file)
    }

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Tracks") {
                Text("\(allTracks.count)")
                    .monospacedDigit()
            }
            LabeledContent("Versions") {
                Text("\(allVersions.count)")
                    .monospacedDigit()
            }
            LabeledContent("Playlists") {
                Text("\(playlistsCount)")
                    .monospacedDigit()
            }
            LabeledContent("Releases") {
                Text("\(releasesCount)")
                    .monospacedDigit()
            }
            LabeledContent("Text Notes") {
                Text("\(textNotesCount)")
                    .monospacedDigit()
            }
            LabeledContent("Voice Notes") {
                Text("\(voiceNotesCount)")
                    .monospacedDigit()
            }
            LabeledContent("Audio on device") {
                Text(formattedAudioSize)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Recovery

    @ViewBuilder
    private var authFailureSection: some View {
        if downloadManager.authFailureThresholdExceeded {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Pairing issue")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("Your Mac no longer recognizes this iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Button {
                    downloadManager.retryAfterAuthFailure()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }

                Button {
                    if let peer = downloadManager.bondedPeerStore.peers.first {
                        peerToForget = peer
                        showForgetAlert = true
                    }
                } label: {
                    Label("Re-pair", systemImage: "link.badge.plus")
                }
            }
        }
    }

    // MARK: - Helpers

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { downloadManager.autoConnectPaused },
            set: { downloadManager.autoConnectPaused = $0 }
        )
    }

    private func startPair(with peer: DiscoveredPeer) {
        guard !isPairing else { return }
        let nonce = PairRequest.freshNonce()
        pendingNonce = nonce
        pairTarget = peer
        pairError = nil
        isPairing = true
        Task {
            do {
                try await downloadManager.pair(with: peer, nonce: nonce)
                isPairing = false
                pairTarget = nil
                pendingNonce = nil
            } catch {
                isPairing = false
                pairError = error.localizedDescription
            }
        }
    }

}

// MARK: - Pair Confirmation Sheet

/// Shown after the user taps a discovered Mac. The Mac displays the same
/// code so the user can confirm the pair request there.
struct PairWaitingSheet: View {
    let peer: DiscoveredPeer
    let nonce: Data
    @Binding var isPairing: Bool
    @Binding var errorMessage: String?
    let onCancel: () -> Void

    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.dismiss) private var dismiss

    private var verificationCode: String {
        PairRequest.verificationCode(
            deviceID: downloadManager.transport.deviceID,
            nonce: nonce
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "desktopcomputer.and.arrow.down")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                        Text(peer.name)
                            .font(.title3.weight(.semibold))
                        Text("Confirm this code on your Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Text(verificationCode)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .tracking(6)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 8)
                        .listRowBackground(Color(.secondarySystemBackground))
                }

                if isPairing {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Waiting for Mac\u{2026}")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .navigationTitle("Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
        .interactiveDismissDisabled(isPairing)
        .onChange(of: downloadManager.bondedPeerStore.peers.count) { _, newCount in
            if newCount > 0 && isPairing {
                isPairing = false
                errorMessage = nil
                dismiss()
            }
        }
    }
}

// MARK: - Sync Log View

struct SyncLogView: View {
    @Environment(DownloadManager.self) private var downloadManager

    var body: some View {
        List {
            if downloadManager.syncLog.isEmpty {
                Text("No sync events logged yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(downloadManager.syncLog.reversed()) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Text(event.date, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        
                        Text(event.message)
                            .font(.subheadline)
                            .foregroundStyle(event.level == .error ? .red : .primary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Sync Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}
