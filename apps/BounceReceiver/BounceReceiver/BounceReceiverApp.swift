import SwiftUI
import SwiftData
import BounceKit

@main
struct BounceReceiverApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var audioPlayer = AudioPlayer()

    var body: some Scene {
        WindowGroup {
            RootViewContainer()
                .environment(audioPlayer)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            audioPlayer.handleScenePhaseChange(newPhase)
        }
        .modelContainer(for: [
            Track.self,
            Version.self,
            Note.self,
            Playlist.self,
            PlaylistEntry.self,
            PlaylistFolder.self,
            SyncCheckpoint.self,
            RemoteTrackSnapshot.self,
            RemoteVersionSnapshot.self,
            PendingUpload.self,
            PendingVoiceUpload.self
        ])
    }
}

enum ReceiverAppStorageKeys {
    static let hasSeenReceiverOnboarding = "com.bounce.hasSeenReceiverOnboarding"
    static let hasEverPairedReceiverDevice = "com.bounce.hasEverPairedReceiverDevice"
}

/// Wraps RootView so we can access modelContext to build DownloadManager.
private struct RootViewContainer: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(ReceiverAppStorageKeys.hasSeenReceiverOnboarding) private var hasSeenReceiverOnboarding = false
    @AppStorage(ReceiverAppStorageKeys.hasEverPairedReceiverDevice) private var hasEverPairedReceiverDevice = false

    @State private var downloadManager: DownloadManager?
    @State private var uploadQueue: UploadQueue?
    @State private var importCoordinator = iOSImportCoordinator()
    @State private var incomingPairLink: PairingLink?
    @State private var presentedPairLink: PairingLink?
    private let resetPairingLaunchArgument = "--reset-pairing-state"

    private var shouldShowReceiverOnboarding: Bool {
        if OnboardingShot.step != nil { return OnboardingShot.forcesOnboarding }
        return !hasEverPairedReceiverDevice && !hasSeenReceiverOnboarding
    }

    private func presentPairLink(_ link: PairingLink) {
        guard downloadManager != nil else { return }
        guard shouldShowReceiverOnboarding else {
            presentedPairLink = link
            return
        }
        incomingPairLink = link
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            presentedPairLink = link
            incomingPairLink = nil
        }
    }

    var body: some View {
        Group {
            if let downloadManager, let uploadQueue {
                if shouldShowReceiverOnboarding {
                    ReceiverOnboardingView(
                        dismissesPairSheet: incomingPairLink != nil,
                        onContinueToLibrary: {
                            hasSeenReceiverOnboarding = true
                        }
                    )
                    .environment(downloadManager)
                    .environment(importCoordinator)
                    .environment(uploadQueue)
                } else {
                    RootView()
                        .environment(downloadManager)
                        .environment(importCoordinator)
                        .environment(uploadQueue)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            }
        }
        .onChange(of: audioPlayer.currentTrack?.artworkRevision) { audioPlayer.refreshNowPlaying() }
        .onChange(of: audioPlayer.currentTrack?.artwork == nil) { audioPlayer.refreshNowPlaying() }
        .sheet(item: $presentedPairLink) { link in
            if let downloadManager {
                PairMacSheet(
                    link: link,
                    onPaired: {
                        hasSeenReceiverOnboarding = true
                        presentedPairLink = nil
                    },
                    onCancel: { presentedPairLink = nil }
                )
                .environment(downloadManager)
                .presentationDetents([.medium, .large])
            }
        }
        .onOpenURL { url in
            guard url.isFileURL else {
                guard let link = try? PairingLink.parse(url) else { return }
                presentPairLink(link)
                return
            }
            Task {
                await importCoordinator.beginImportReview(for: url, context: modelContext)
            }
        }
        .onAppear {
            audioPlayer.setModelContext(modelContext)
            OnboardingShot.seedLibrary(modelContext, audioPlayer: audioPlayer)
            if downloadManager == nil {
                if ProcessInfo.processInfo.arguments.contains(resetPairingLaunchArgument) {
                    BonjourTransport.resetLocalPairingState()
                }
                SchemaBackfill.backfillLastTouchedAt(in: modelContext)
                // Off the launch critical path: the phone carries the same synced legacy
                // blobs as the Mac, so it needs the same backfill. Runs against its own
                // ModelContext so decoding/downsampling large legacy covers never blocks
                // the first frame.
                Task(priority: .utility) {
                    await SchemaBackfill.backfillOversizedArtwork(container: modelContext.container)
                }
                let dm = DownloadManager(modelContext: modelContext)
                dm.onWillRemoveAudio = { [audioPlayer] trackIDs, versionIDs in
                    audioPlayer.handleRemovedAudio(trackIDs: trackIDs, versionIDs: versionIDs)
                }
                if !dm.bondedPeerStore.peers.isEmpty {
                    hasEverPairedReceiverDevice = true
                    hasSeenReceiverOnboarding = true
                }
                let uq = UploadQueue(transport: dm.transport, modelContext: modelContext)
                downloadManager = dm
                DebugLog.log("app launched")
                uploadQueue = uq
                Task {
                    await dm.start()
                    uq.startObserving()

                    uq.onQueueDrained = { [weak dm] in
                        guard let dm, case .connected = dm.transport.connectionState else { return }
                        dm.notifyLocalManifestMutated()
                    }
                }
            }
        }
        .onChange(of: importCoordinator.importedCount) { _, _ in
            uploadQueue?.drainQueue()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                downloadManager?.triggerReconnect()
            }
        }
    }
}
