import SwiftUI
import SwiftData
import UIKit
import BounceKit

struct VoiceNoteComposerMic: UIViewRepresentable {
    @Bindable var controller: VoiceNoteInteractionController
    let track: Track
    let audioPlayer: AudioPlayer
    let modelContext: ModelContext
    let downloadManager: DownloadManager
    let uploadQueue: UploadQueue

    func makeUIView(context: Context) -> VoiceNoteMicUIView {
        let view = VoiceNoteMicUIView()
        view.controller = controller
        view.track = track
        view.audioPlayer = audioPlayer
        view.modelContext = modelContext
        view.downloadManager = downloadManager
        view.uploadQueue = uploadQueue
        return view
    }

    func updateUIView(_ uiView: VoiceNoteMicUIView, context: Context) {
        uiView.controller = controller
        uiView.track = track
        uiView.audioPlayer = audioPlayer
        uiView.modelContext = modelContext
        uiView.downloadManager = downloadManager
        uiView.uploadQueue = uploadQueue
    }
}

final class VoiceNoteMicUIView: UIView {
    var controller: VoiceNoteInteractionController?
    var track: Track?
    var audioPlayer: AudioPlayer?
    var modelContext: ModelContext?
    var downloadManager: DownloadManager?
    var uploadQueue: UploadQueue?

    private var longPress: UILongPressGestureRecognizer!
    private var pan: UIPanGestureRecognizer!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let imageView = UIImageView(image: UIImage(systemName: "mic", withConfiguration: config))
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .white
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22),
        ])

        longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0
        longPress.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(longPress)

        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let controller, let track, let audioPlayer else { return }
        switch gesture.state {
        case .began:
            let holdTimestamp = audioPlayer.playbackClock.time
            controller.beginHold(
                track: track,
                version: audioPlayer.currentVersion,
                timestamp: holdTimestamp,
                audioPlayer: audioPlayer
            )
        case .ended, .cancelled:
            if controller.state.isHolding {
                guard let modelContext, let downloadManager, let uploadQueue else { return }
                controller.endHold(
                    modelContext: modelContext,
                    downloadManager: downloadManager,
                    uploadQueue: uploadQueue
                )
            }
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let controller else { return }
        let translation = gesture.translation(in: self)
        controller.updateDrag(translation: CGSize(width: translation.x, height: translation.y))
    }
}

extension VoiceNoteMicUIView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
