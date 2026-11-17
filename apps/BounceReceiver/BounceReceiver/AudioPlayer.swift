import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import SwiftData
import BounceKit

@Observable
@MainActor
final class AudioPlayer: NSObject {
    var currentTrack: Track?
    var currentVersion: Version?
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var loadError: String? = nil

    var displayTime: TimeInterval = 0

    let playbackClock = PlaybackClock()

    var isScrubbing: Bool = false
    var showFullScreenPlayer: Bool = false
    var isKeyboardVisible: Bool = false
    var showsMiniPlayer: Bool { currentTrack != nil && !isKeyboardVisible }

    var fullScreenPlayerOpenToken: Int = 0

    var canAutoAdvance: Bool = true {
        didSet {
            guard canAutoAdvance != oldValue, player != nil else { return }
            enqueueNext()
        }
    }

    enum QueueContext {
        case single
        case autoplayLibrary
        case playlist
        case releases
        case sets

        var continuesRegardlessOfAutoplay: Bool {
            switch self {
            case .playlist, .releases, .sets: return true
            case .single, .autoplayLibrary: return false
            }
        }
    }

    var queueContext: QueueContext = .single
    var queue: [Track] = []
    var queueIndex: Int = 0

    enum RepeatMode: String {
        case off, all, one
        var next: RepeatMode {
            switch self {
            case .off: return .all
            case .all: return .one
            case .one: return .off
            }
        }
    }

    var shuffleEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(shuffleEnabled, forKey: AudioPlayer.shuffleModeKey)
            guard shuffleEnabled != oldValue else { return }
            if shuffleEnabled { shuffleQueue() } else { unshuffleQueue() }
            if player != nil { enqueueNext() }
        }
    }

    var repeatMode: RepeatMode = .off {
        didSet {
            UserDefaults.standard.set(repeatMode.rawValue, forKey: AudioPlayer.repeatModeKey)
            if player != nil { enqueueNext() }
        }
    }

    var autoplayEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(autoplayEnabled, forKey: AudioPlayer.autoplayKey)
            guard autoplayEnabled != oldValue, player != nil else { return }
            enqueueNext()
        }
    }

    private static let shuffleModeKey = "com.bounce.shuffleMode"
    private static let repeatModeKey = "com.bounce.repeatMode"
    private static let autoplayKey = "com.bounce.autoplay"

    private var unshuffledOrder: [UUID] = []
    private var queueVersionIDs: [UUID: UUID] = [:]

    var player: AVPlayer?
    private var queuePlayer: AVQueuePlayer? { player as? AVQueuePlayer }
    private var timeObserver: Any?
    private var currentItemObservation: NSKeyValueObservation?

    private struct QueuedEntry {
        let item: AVPlayerItem
        let track: Track
        let version: Version
        let queueIndex: Int
    }
    private var queuedEntries: [QueuedEntry] = []
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false
    private var lastNowPlayingRefreshTime: TimeInterval = 0

    private var displayLink: CADisplayLink?
    private var lastObserverTime: TimeInterval = 0
    private var lastObserverDate: Date = .distantPast
    private var lastPersistedResumePosition: TimeInterval = 0
    private var pendingSeekTarget: TimeInterval? = nil
    @ObservationIgnored private var userSeekedSinceLoad = false

    private var cachedArtwork: (trackID: UUID, revision: Int64?, image: UIImage)? = nil

    private let session = AVAudioSession.sharedInstance()
    @ObservationIgnored private var modelContext: ModelContext?
    private(set) var waveformRefreshToken: Int = 0
    @ObservationIgnored private var waveformRefreshesInFlight: Set<UUID> = []

    private static let resumeWriteInterval: TimeInterval = 5
    private static let resumeThreshold: TimeInterval = ResumePolicy.threshold

    func setModelContext(_ context: ModelContext) {
        modelContext = context
    }

    func openFullScreenPlayer() {
        showFullScreenPlayer = true
        fullScreenPlayerOpenToken &+= 1
        seedPlaybackClockFromPlayer()
        if isPlaying { startDisplayLink() }
        ensurePlaybackActive()
    }

    func dismissPlayer() {
        showFullScreenPlayer = false
        stopDisplayLink()
        ensurePlaybackActive()
    }

    private func seedPlaybackClockFromPlayer() {
        let t: TimeInterval
        if let playerTime = player?.currentTime().seconds, playerTime.isFinite {
            t = playerTime
        } else {
            t = currentTime
        }
        playbackClock.time = t
        displayTime = t
        lastObserverTime = t
        lastObserverDate = Date()
    }

    func ensurePlaybackActive() {
        guard isPlaying else { return }
        activateAudioSession()
        if let player, player.timeControlStatus != .playing {
            player.play()
        }
    }

    func handleDeletedTracks(_ trackIDs: Set<UUID>) {
        handleRemovedAudio(trackIDs: trackIDs, versionIDs: [])
    }

    func handleRemovedAudio(trackIDs: Set<UUID>, versionIDs: Set<UUID>) {
        guard !trackIDs.isEmpty || !versionIDs.isEmpty else { return }
        let emptiedTrackIDs = queue.filter { track in
            !track.versions.isEmpty && track.versions.allSatisfy { versionIDs.contains($0.id) }
        }.map(\.id)
        let removedTrackIDs = trackIDs.union(emptiedTrackIDs)

        let currentTrackRemoved = currentTrack.map { removedTrackIDs.contains($0.id) } ?? false
        let currentVersionRemoved = currentVersion.map { versionIDs.contains($0.id) } ?? false
        if currentTrackRemoved || currentVersionRemoved {
            stopAndClear()
            return
        }

        PlayQueueOps.prune(id: \.id, removing: removedTrackIDs, queue: &queue, index: &queueIndex)
        manuallyQueuedIDs.subtract(removedTrackIDs)
        if player != nil { enqueueNext(excludingVersionIDs: versionIDs) }
    }

    private func stopAndClear() {
        tearDownPlayer()
        currentTrack = nil
        currentVersion = nil
        loadError = nil
        showFullScreenPlayer = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        queue = []
        queueIndex = 0
        queueVersionIDs = [:]
        manuallyQueuedIDs.removeAll()
    }

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AudioPlayer.shuffleModeKey) != nil {
            shuffleEnabled = defaults.bool(forKey: AudioPlayer.shuffleModeKey)
        }
        if let raw = defaults.string(forKey: AudioPlayer.repeatModeKey),
           let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        if defaults.object(forKey: AudioPlayer.autoplayKey) != nil {
            autoplayEnabled = defaults.bool(forKey: AudioPlayer.autoplayKey)
        }
        setupAudioSession()
        setupRemoteCommandCenter()
    }

    func load(track: Track, version: Version? = nil, queue: [Track]? = nil, queueVersions: [UUID: UUID] = [:], context: QueueContext? = nil, startTime: TimeInterval? = nil, autoPlay: Bool = true) {
        let addsDuringCancelledPark = cancelParkedLoad()
        defer { addsDuringCancelledPark.forEach(addToQueue) }
        let versionPins = queue == nil ? queueVersionIDs : queueVersions
        let targetVersion = version ?? Self.version(of: track, pins: versionPins)
        guard let version = targetVersion else {
            loadError = "No versions available for \"\(track.name)\""
            print("[AudioPlayer] ERROR: No versions available for track \(track.id)")
            return
        }
        let filePath = version.filePath

        guard FileManager.default.fileExists(atPath: filePath) else {
            let msg = "File not found on disk: \(filePath)"
            print("[AudioPlayer] ERROR: \(msg)")
            loadError = msg
            return
        }

        let fileURL = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: fileURL)
        let item = AVPlayerItem(asset: asset)
        Task.detached(priority: .userInitiated) {
            _ = try? await asset.load(.isPlayable, .duration)
        }

        persistResumePosition(force: true)
        tearDownPlayer(resetState: false)
        userSeekedSinceLoad = false

        currentTime = 0
        displayTime = 0
        playbackClock.time = 0
        lastObserverTime = 0
        lastPersistedResumePosition = version.resumePosition
        pendingSeekTarget = nil

        let newPlayer = AVQueuePlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .advance

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                guard !self.isScrubbing else { return }
                guard self.player?.currentItem === self.queuedEntries.first?.item else { return }
                if let target = self.pendingSeekTarget {
                    guard abs(seconds - target) < 0.3 else { return }
                    self.pendingSeekTarget = nil
                }
                self.currentTime = seconds
                self.lastObserverTime = seconds
                self.lastObserverDate = Date()
                self.playbackClock.time = seconds
                self.displayTime = seconds
                if self.duration <= 0,
                   let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }

                self.persistResumePosition(at: seconds)

                guard self.isPlaying, abs(seconds - self.lastNowPlayingRefreshTime) >= 1 else { return }
                self.lastNowPlayingRefreshTime = seconds
                self.updateNowPlaying()
            }
        }

        currentItemObservation = newPlayer.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.handleCurrentItemChange(player.currentItem)
            }
        }

        player = newPlayer
        currentTrack = track
        currentVersion = version
        lastPersistedResumePosition = version.resumePosition
        loadError = nil

        let waveformBlob = version.waveformData
        let versionID = version.id
        if let artwork = track.artwork {
            _ = ArtworkImageCache.shared.image(for: track.id, data: artwork, pointSize: 32)
        }
        Task.detached(priority: .userInitiated) {
            WaveformSampleCache.shared.prewarm(versionID: versionID, data: waveformBlob)
        }
        scheduleSparseWaveformRefresh(for: version)

        if let newQueue = queue {
            let userQueue = upNextTracks.filter { manuallyQueuedIDs.contains($0.id) && $0.id != track.id }
            self.queue = newQueue
            self.queueIndex = newQueue.firstIndex(where: { $0.id == track.id }) ?? 0
            unshuffledOrder = newQueue.map(\.id)
            queueVersionIDs = queueVersions
            var keptUserQueue: Set<UUID> = []
            for queued in userQueue {
                PlayQueueOps.addToQueue(queued, id: \.id, queue: &self.queue, index: &queueIndex, queued: keptUserQueue)
                keptUserQueue.insert(queued.id)
            }
            manuallyQueuedIDs = keptUserQueue
            if let context { self.queueContext = context }
            if shuffleEnabled { shuffleQueue() }
        } else if self.queue.indices.contains(queueIndex), self.queue[queueIndex].id == track.id {
            if let context { self.queueContext = context }
        } else if let idx = self.queue.firstIndex(where: { $0.id == track.id }) {
            self.queueIndex = idx
            if let context { self.queueContext = context }
        } else {
            let libraryQueue = libraryContext(for: track)
            self.queue = libraryQueue
            self.queueIndex = libraryQueue.firstIndex(where: { $0.id == track.id }) ?? 0
            unshuffledOrder = libraryQueue.map(\.id)
            queueVersionIDs = [:]
            self.manuallyQueuedIDs.removeAll()
            self.queueContext = context ?? .autoplayLibrary
            if shuffleEnabled { shuffleQueue() }
        }
        queueVersionIDs[track.id] = version.id
        manuallyQueuedIDs.remove(track.id)

        queuedEntries = [QueuedEntry(
            item: item,
            track: track,
            version: version,
            queueIndex: queueIndex
        )]

        let targetVersionID = version.id
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                if item.status == .readyToPlay {
                    let itemDuration = item.duration.seconds
                    self.duration = itemDuration.isFinite ? itemDuration : 0
                    if let startTime {
                        self.applySeek(to: startTime)
                    } else if self.currentVersion?.id == targetVersionID,
                              let currentVersion = self.currentVersion,
                              let resume = self.resumePosition(for: currentVersion, duration: self.duration) {
                        self.applySeek(to: resume)
                    } else {
                        self.currentTime = 0
                        self.displayTime = 0
                        self.playbackClock.time = 0
                    }
                    if autoPlay {
                        self.play()
                    }
                    self.enqueueNext()
                } else if item.status == .failed {
                    self.loadError = item.error?.localizedDescription ?? "Failed to load audio"
                    print("[AudioPlayer] ERROR: \(self.loadError ?? "")")
                }
            }
        }
    }

    private var itemStatusObservation: NSKeyValueObservation?

    private static func version(of track: Track, pins: [UUID: UUID]) -> Version? {
        if let pinnedID = pins[track.id], let pinned = track.versions.first(where: { $0.id == pinnedID }) {
            return pinned
        }
        return track.latestVersion ?? track.versions.first
    }

    private typealias QueueCandidate = (track: Track, version: Version, queueIndex: Int)

    private func computeNext(excludingVersionIDs excluded: Set<UUID>) -> QueueCandidate? {
        guard queue.indices.contains(queueIndex) else { return nil }
        if repeatMode == .one { return playableCandidate(at: queueIndex, excludingVersionIDs: excluded) }
        var order = Array(queue.indices.dropFirst(queueIndex + 1))
        if repeatMode == .all { order += queue.indices.prefix(queueIndex + 1) }
        return firstPlayableCandidate(in: order, excludingVersionIDs: excluded)
    }

    private func playableCandidate(at index: Int, excludingVersionIDs excluded: Set<UUID> = []) -> QueueCandidate? {
        let track = queue[index]
        guard let version = Self.version(of: track, pins: queueVersionIDs),
              !excluded.contains(version.id),
              FileManager.default.fileExists(atPath: version.filePath) else { return nil }
        return (track, version, index)
    }

    private func firstPlayableCandidate(in order: [Int], excludingVersionIDs excluded: Set<UUID> = []) -> QueueCandidate? {
        for index in order {
            if let candidate = playableCandidate(at: index, excludingVersionIDs: excluded) { return candidate }
        }
        return nil
    }

    private func enqueueNext(excludingVersionIDs excluded: Set<UUID> = []) {
        guard let qp = queuePlayer, let current = queuedEntries.first else { return }

        while queuedEntries.count > 1 {
            let stale = queuedEntries.removeLast()
            qp.remove(stale.item)
        }

        guard canAutoAdvance, let next = computeNext(excludingVersionIDs: excluded), shouldAutoAdvance(into: next.track) else { return }
        let version = next.version

        let asset = AVURLAsset(url: URL(fileURLWithPath: version.filePath))
        let item = AVPlayerItem(asset: asset)
        guard qp.canInsert(item, after: current.item) else { return }
        qp.insert(item, after: current.item)
        queuedEntries.append(QueuedEntry(
            item: item,
            track: next.track,
            version: version,
            queueIndex: next.queueIndex
        ))

        Task.detached(priority: .utility) {
            _ = try? await asset.load(.isPlayable, .duration)
        }
        let versionID = version.id
        let waveformBlob = version.waveformData
        if let artwork = next.track.artwork {
            _ = ArtworkImageCache.shared.image(for: next.track.id, data: artwork, pointSize: 32)
        }
        Task.detached(priority: .utility) {
            WaveformSampleCache.shared.prewarm(versionID: versionID, data: waveformBlob)
        }
    }

    private func handleCurrentItemChange(_ item: AVPlayerItem?) {
        guard let item else {
            handleQueueEnd()
            return
        }
        guard queuedEntries.count > 1, queuedEntries[1].item === item else { return }

        let entry = queuedEntries[1]
        queuedEntries.removeFirst()

        persistResumePosition(at: duration, force: true, reset: true)
        userSeekedSinceLoad = false

        currentTrack = entry.track
        currentVersion = entry.version
        queueIndex = entry.queueIndex
        manuallyQueuedIDs.remove(entry.track.id)
        loadError = nil

        currentTime = 0
        displayTime = 0
        playbackClock.time = 0
        lastObserverTime = 0
        lastObserverDate = Date()
        lastNowPlayingRefreshTime = 0

        let d = item.duration.seconds
        duration = (d.isFinite && d > 0) ? d : 0
        lastPersistedResumePosition = entry.version.resumePosition
        pendingSeekTarget = nil
        if let resume = resumePosition(for: entry.version, duration: duration > 0 ? duration : entry.version.duration) {
            applySeek(to: resume)
        }

        if !entry.version.hasBeenPlayed { entry.version.hasBeenPlayed = true }

        let versionID = entry.version.id
        let waveformBlob = entry.version.waveformData
        if let artwork = entry.track.artwork {
            _ = ArtworkImageCache.shared.image(for: entry.track.id, data: artwork, pointSize: 32)
        }
        Task.detached(priority: .userInitiated) {
            WaveformSampleCache.shared.prewarm(versionID: versionID, data: waveformBlob)
        }
        scheduleSparseWaveformRefresh(for: entry.version)

        updateNowPlaying()

        enqueueNext()
    }

    private func handleQueueEnd() {
        isPlaying = false
        stopDisplayLink()
        if let track = currentTrack {
            let finishedVersion = currentVersion
            persistResumePosition(at: duration, force: true, reset: true)
            currentVersion = nil
            load(track: track, version: finishedVersion, startTime: 0, autoPlay: false)
            if currentVersion == nil { stopAndClear() }
        } else {
            currentTime = 0
            displayTime = 0
            playbackClock.time = 0
            lastObserverTime = 0
            lastNowPlayingRefreshTime = 0
            updateNowPlaying()
        }
    }

    func play() {
        guard let player else { return }
        activateAudioSession()
        if duration > 0 && currentTime >= duration - 0.1 {
            player.seek(to: .zero)
            currentTime = 0
            displayTime = 0
            playbackClock.time = 0
            persistResumePosition(at: 0, force: true, reset: true)
        }
        player.play()
        isPlaying = true
        wasPlayingBeforeInterruption = false
        lastObserverDate = Date()
        if let version = currentVersion, !version.hasBeenPlayed {
            version.hasBeenPlayed = true
        }
        if showFullScreenPlayer {
            startDisplayLink()
        }
        updateNowPlaying()
    }

    func pause() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        stopDisplayLink()
        persistResumePosition(force: true)
        updateNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: TimeInterval) {
        userSeekedSinceLoad = true
        applySeek(to: time)
    }

    private func applySeek(to time: TimeInterval) {
        let clamped: TimeInterval
        if duration > 0 {
            clamped = max(0, min(duration, time))
        } else {
            clamped = max(0, time)
        }
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        pendingSeekTarget = clamped
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        displayTime = clamped
        playbackClock.time = clamped
        lastObserverTime = clamped
        lastObserverDate = Date()
        updateNowPlaying()
    }

    private var nextOrder: [Int] {
        var order = Array(queue.indices.dropFirst(queueIndex + 1))
        if repeatMode != .off { order += queue.indices.prefix(queueIndex) }
        return order
    }

    private var previousOrder: [Int] {
        var order = Array(queue.indices.prefix(queueIndex).reversed())
        if repeatMode != .off { order += queue.indices.dropFirst(queueIndex + 1).reversed() }
        return order
    }

    var peekNextTrack: Track? {
        firstPlayableCandidate(in: nextOrder)?.track
    }

    var peekPreviousTrack: Track? {
        firstPlayableCandidate(in: previousOrder)?.track
    }

    func next() {
        guard !queue.isEmpty else { return }

        if let candidate = firstPlayableCandidate(in: nextOrder) {
            load(track: candidate.track, version: candidate.version)
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }

        if currentTime > Self.previousRestartThreshold {
            seek(to: 0)
            return
        }

        skipToPreviousTrack()
    }

    func skipToPreviousTrack() {
        guard !queue.isEmpty else { return }

        if let candidate = firstPlayableCandidate(in: previousOrder) {
            load(track: candidate.track, version: candidate.version)
        } else {
            seek(to: 0)
        }
    }

    private static let previousRestartThreshold: TimeInterval = 3

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
    }

    func toggleAutoplay() {
        autoplayEnabled.toggle()
    }

    private func shouldAutoAdvance(into next: Track) -> Bool {
        if repeatMode != .off { return true }
        if manuallyQueuedIDs.contains(next.id) { return true }
        if queueContext.continuesRegardlessOfAutoplay { return true }
        if queueContext == .autoplayLibrary { return autoplayEnabled }
        return false
    }

    private func shuffleQueue() {
        PlayQueueOps.shuffle(id: \.id, pinned: manuallyQueuedIDs, queue: &queue, index: &queueIndex)
    }

    private func unshuffleQueue() {
        PlayQueueOps.unshuffle(
            id: \.id,
            pinned: manuallyQueuedIDs,
            originalOrder: unshuffledOrder,
            queue: &queue,
            index: &queueIndex
        )
    }

    private(set) var manuallyQueuedIDs: Set<UUID> = []

    @ObservationIgnored private var parkedLoad: Task<Void, Never>?
    @ObservationIgnored private var addedWhileParking: [Track] = []

    func addToQueue(_ track: Track) {
        if parkedLoad != nil { addedWhileParking.append(track); return }
        guard currentTrack != nil else { loadParked(track); return }
        guard PlayQueueOps.addToQueue(track, id: \.id, queue: &queue, index: &queueIndex, queued: manuallyQueuedIDs) else { return }
        manuallyQueuedIDs.insert(track.id)
        queueVersionIDs[track.id] = nil
        if player != nil { enqueueNext() }
    }

    private func loadParked(_ track: Track) {
        parkedLoad = Task { [weak self] in
            guard let self else { return }
            let context = await self.libraryContextOffMain(for: track)
            guard !Task.isCancelled else { return }
            self.load(track: track, queue: context, context: .autoplayLibrary, autoPlay: false)
        }
    }

    private func cancelParkedLoad() -> [Track] {
        guard let parkedLoad else { return [] }
        parkedLoad.cancel()
        self.parkedLoad = nil
        defer { addedWhileParking = [] }
        return addedWhileParking
    }

    private func libraryContext(for track: Track) -> [Track] {
        guard let modelContext else { return [track] }
        do {
            return try Self.libraryContext(for: track, in: modelContext, hidesSets: Self.hidesSets)
        } catch {
            print("[AudioPlayer] ERROR: library fetch for playback context failed: \(error)")
            return [track]
        }
    }

    private func libraryContextOffMain(for track: Track) async -> [Track] {
        guard let modelContext else { return [track] }
        let container = modelContext.container
        let trackID = track.persistentModelID
        let hidesSets = Self.hidesSets
        let result: Result<[PersistentIdentifier], Error> = await Task.detached(priority: .userInitiated) {
            let background = ModelContext(container)
            guard let backgroundTrack = background.model(for: trackID) as? Track else { return .success([trackID]) }
            return Result {
                try Self.libraryContext(for: backgroundTrack, in: background, hidesSets: hidesSets).map(\.persistentModelID)
            }
        }.value
        switch result {
        case .success(let ids):
            let tracks = ids.compactMap { modelContext.model(for: $0) as? Track }
            return tracks.contains(where: { $0.id == track.id }) ? tracks : [track]
        case .failure(let error):
            print("[AudioPlayer] ERROR: library fetch for playback context failed: \(error)")
            return [track]
        }
    }

    private static var hidesSets: Bool {
        UserDefaults.standard.bool(forKey: BouncePreferenceKey.showSetsTab)
    }

    nonisolated private static func libraryContext(for track: Track, in context: ModelContext, hidesSets: Bool) throws -> [Track] {
        let tracks = try context.fetch(FetchDescriptor<Track>())
        let songs = hidesSets ? tracks.filter { !$0.isSet } : tracks
        return LibrarySorting.playbackContext(for: track, in: LibrarySorting.allTracksOrder(songs))
    }

    var upNextCount: Int {
        max(0, queue.count - queueIndex - 1)
    }

    var manualQueueCount: Int {
        let ids = manuallyQueuedIDs
        return upNextTracks.lazy.filter { ids.contains($0.id) }.count
    }

    var upNextTracks: [Track] {
        guard queueIndex + 1 < queue.count else { return [] }
        return Array(queue[(queueIndex + 1)...])
    }

    func removeFromUpNext(at offset: Int) {
        let absolute = queueIndex + 1 + offset
        guard absolute < queue.count else { return }
        let removed = queue.remove(at: absolute)
        manuallyQueuedIDs.remove(removed.id)
        if player != nil { enqueueNext() }
    }

    func playUpNext(at offset: Int) {
        let absolute = queueIndex + 1 + offset
        guard absolute < queue.count else { return }
        guard let target = playableCandidate(at: absolute) else {
            loadError = "\(queue[absolute].displayTitle) is not downloaded"
            return
        }
        for skipped in queue[(queueIndex + 1)..<absolute] {
            manuallyQueuedIDs.remove(skipped.id)
        }
        load(track: target.track, version: target.version)
    }

    func clearUpNext() {
        guard queueIndex + 1 < queue.count else { return }
        let removedIDs = queue[(queueIndex + 1)...].map(\.id)
        queue.removeSubrange((queueIndex + 1)...)
        for id in removedIDs { manuallyQueuedIDs.remove(id) }
        if player != nil { enqueueNext() }
    }

    var currentFileURL: URL? {
        guard let path = currentVersion?.filePath else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: path) ? url : nil
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard isPlaying else { return }
            activateAudioSession()
            if let t = player?.currentTime().seconds, t.isFinite {
                lastObserverTime = t
                displayTime = t
                playbackClock.time = t
            }
            lastObserverDate = Date()
            updateNowPlaying()
        case .background:
            persistResumePosition(force: true)
            if isPlaying { updateNowPlaying() }
        case .inactive:
            persistResumePosition(force: true)
        @unknown default:
            break
        }
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        guard isPlaying, !isScrubbing else { return }
        let elapsed = Date().timeIntervalSince(lastObserverDate)
        let interpolated = lastObserverTime + elapsed
        playbackClock.time = min(interpolated, duration)
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func setupAudioSession() {
        do {
            try session.setCategory(.playback, mode: .default)
        } catch {
            print("[AudioPlayer] Audio session setup failed: \(error)")
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleAudioSessionInterruption(notification)
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleAudioRouteChange(notification)
            }
        }

        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        }
    }

    private func handleMediaServicesReset() {
        do {
            try session.setCategory(.playback, mode: .default)
        } catch {
            print("[AudioPlayer] Audio session setup after media services reset failed: \(error)")
        }
        guard let track = currentTrack, let version = currentVersion else { return }
        let position = currentTime
        isPlaying = false
        load(track: track, version: version, startTime: position, autoPlay: false)
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentTrack?.displayTitle ?? ""
        if let artist = currentTrack?.artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let track = currentTrack {
            let image: UIImage
            if track.artwork != nil,
               let cached = cachedArtwork, cached.trackID == track.id, cached.revision == track.artworkRevision {
                image = cached.image
            } else if let artworkData = track.artwork, let decoded = UIImage(data: artworkData) {
                cachedArtwork = (trackID: track.id, revision: track.artworkRevision, image: decoded)
                image = decoded
            } else {
                image = Self.placeholderArtwork
            }
            let bounds = CGSize(width: Self.nowPlayingArtworkSide, height: Self.nowPlayingArtworkSide)
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: bounds) { _ in image }
        }
        lastNowPlayingRefreshTime = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func refreshNowPlaying() {
        guard currentTrack != nil else { return }
        updateNowPlaying()
    }

    private static let nowPlayingArtworkSide: CGFloat = 600
    private static let placeholderArtwork: UIImage = {
        let side = nowPlayingArtworkSide
        let view = ZStack {
            Color.black
            Color(.tertiarySystemFill)
            Image(systemName: "music.note")
                .font(.system(size: side * 0.27))
                .foregroundStyle(.secondary)
        }
        .frame(width: side, height: side)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.uiImage else {
            print("[AudioPlayer] ERROR: placeholder artwork render failed")
            return UIImage()
        }
        return image
    }()

    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, !self.queue.isEmpty else { return .noSuchContent }
            guard self.canAutoAdvance else { return .commandFailed }
            self.next()
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, !self.queue.isEmpty else { return .noSuchContent }
            guard self.canAutoAdvance else { return .commandFailed }
            self.previous()
            return .success
        }
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            isPlaying = false
            updateNowPlaying()
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = wasPlayingBeforeInterruption && options.contains(.shouldResume)
            wasPlayingBeforeInterruption = false

            guard shouldResume else {
                updateNowPlaying()
                return
            }

            play()
        @unknown default:
            break
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        guard reason == .oldDeviceUnavailable, isPlaying else { return }
        pause()
    }

    private func activateAudioSession() {
        do {
            try session.setActive(true)
        } catch {
            print("[AudioPlayer] Failed to activate audio session: \(error)")
        }
    }

    private func persistResumePosition(
        at position: TimeInterval? = nil,
        force: Bool = false,
        reset: Bool = false
    ) {
        guard let version = currentVersion, ResumePolicy.shouldTrack(isSet: currentTrack?.isSet == true) else { return }
        let observed = position ?? player?.currentTime().seconds ?? currentTime
        guard observed.isFinite else { return }
        let value = reset ? 0 : max(0, observed)
        if !force && abs(value - lastPersistedResumePosition) < Self.resumeWriteInterval {
            return
        }
        if !reset && !userSeekedSinceLoad && value < Self.resumeThreshold && !isPlaying,
           version.resumePosition >= Self.resumeThreshold {
            return
        }
        version.resumePosition = value
        lastPersistedResumePosition = value
        try? modelContext?.save()
    }

    private func scheduleSparseWaveformRefresh(for version: Version) {
        let duration = version.duration > 0 ? version.duration : duration
        let sampleCount = WaveformMetrics.floatCount(in: version.waveformData)
        guard WaveformMetrics.needsDenserWaveform(sampleCount: sampleCount, duration: duration) else {
            return
        }
        let path = version.filePath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }

        let versionID = version.id
        guard !waveformRefreshesInFlight.contains(versionID) else { return }
        waveformRefreshesInFlight.insert(versionID)
        Task { @MainActor [weak self] in
            let processor = WaveformProcessor()
            let data = try? await processor.process(fileURL: URL(fileURLWithPath: path))
            guard let self else { return }
            self.waveformRefreshesInFlight.remove(versionID)
            var descriptor = FetchDescriptor<Version>(predicate: #Predicate { $0.id == versionID })
            descriptor.fetchLimit = 1
            guard let data, let target = try? self.modelContext?.fetch(descriptor).first else { return }
            target.waveformData = data
            try? self.modelContext?.save()
            guard self.currentVersion?.id == versionID else { return }
            self.waveformRefreshToken &+= 1
            Task.detached(priority: .utility) {
                WaveformSampleCache.shared.prewarm(versionID: versionID, data: data)
            }
        }
    }

    private func resumePosition(for version: Version, duration: TimeInterval) -> TimeInterval? {
        let isSet = currentTrack?.isSet == true
        let saved = version.resumePosition
        if let position = ResumePolicy.resumePosition(isSet: isSet, saved: saved, duration: duration) {
            return position
        }
        if isSet, ResumePolicy.isFinished(saved: saved, duration: duration) {
            version.resumePosition = 0
            lastPersistedResumePosition = 0
            try? modelContext?.save()
        }
        return nil
    }

    private func tearDownPlayer(resetState: Bool = true) {
        persistResumePosition(force: true)
        stopDisplayLink()

        currentItemObservation = nil
        itemStatusObservation = nil

        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        player?.pause()
        queuePlayer?.removeAllItems()
        queuedEntries = []
        player = nil

        guard resetState else { return }

        isPlaying = false
        currentTime = 0
        displayTime = 0
        playbackClock.time = 0
        duration = 0
        lastObserverTime = 0
        lastNowPlayingRefreshTime = 0
    }
}

final class PlaybackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _time: TimeInterval = 0

    var time: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _time
        }
        set {
            lock.lock()
            _time = newValue
            lock.unlock()
        }
    }
}
