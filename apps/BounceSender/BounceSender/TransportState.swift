import Foundation
import Observation

enum TransportRepeatMode: String {
    case off
    case all
    case one
}

struct TransportQueueItem: Identifiable, Equatable {
    let id: UUID // versionID
    let trackID: UUID
    let title: String
    let subtitle: String
    let isCurrent: Bool
}

@Observable
final class TransportState {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var loadedVersionID: UUID?
    var loadedTitle = ""
    var loadedMixLabel = ""
    var waveformSamples: [Float]? = nil
    var noteTimestamps: [TimeInterval] = []
    var shuffleEnabled = false
    var repeatMode: TransportRepeatMode = .off
    var queueItems: [TransportQueueItem] = []
    var upNextQueueItems: [TransportQueueItem] = []
    var continueQueueItems: [TransportQueueItem] = []
    var volume: Float = 1.0
    var onTogglePlayback: (() -> Void)?
    var onSkipBackward: (() -> Void)?
    var onSkipForward: (() -> Void)?
    var onAddNote: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onToggleShuffle: (() -> Void)?
    var onCycleRepeatMode: (() -> Void)?
    var onPlayQueueItem: ((UUID) -> Void)?
    var onClearUpNextQueue: (() -> Void)?
    var onSetVolume: ((Float) -> Void)?
    /// Set to true to request the notes input to focus (cleared by the observer)
    var requestNoteFocus = false
}
