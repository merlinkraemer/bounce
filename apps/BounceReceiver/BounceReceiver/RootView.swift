import SwiftUI
import BounceKit

/// Mini-player capsule (44pt button + 8pt vertical padding ×2 = 60pt) plus
/// its 8pt outer bottom padding = 68pt total occupied height. Reserve a bit
/// more so the last list row clears the bar with visible breathing room.
private let miniPlayerReservedHeight: CGFloat = 76

struct RootView: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(\.modelContext) private var modelContext
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(UploadQueue.self) private var uploadQueue

    var body: some View {
        ZStack(alignment: .bottom) {
            LibraryView()

            // Mini player — always visible when track loaded, full player slides over it
            if audioPlayer.showsMiniPlayer {
                MiniPlayerBar(onTap: { audioPlayer.openFullScreenPlayer() })
            }

            // Keep the sheet VC mounted even with no track so viewDidLoad /
            // first layout happen before the user opens fullscreen.
            PlayerSheet(
                isPresented: audioPlayer.showFullScreenPlayer,
                openToken: audioPlayer.fullScreenPlayerOpenToken,
                onDismiss: { audioPlayer.dismissPlayer() },
                audioPlayer: audioPlayer,
                modelContext: modelContext,
                downloadManager: downloadManager,
                uploadQueue: uploadQueue
            )
            .ignoresSafeArea()
            // Hit testing follows the SwiftUI flag. Collapse clears the flag
            // immediately so this layer cannot sit invisible and eat taps.
            .allowsHitTesting(audioPlayer.showFullScreenPlayer)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            audioPlayer.isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            audioPlayer.isKeyboardVisible = false
        }
        .task {
            if OnboardingShot.opensPlayer {
                try? await Task.sleep(for: .seconds(2))
                audioPlayer.openFullScreenPlayer()
            }
        }
    }
}
