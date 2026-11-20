import Foundation
import SwiftData
import AVFoundation
import BounceKit

/// IDs of the SwiftData rows scheduled by the optimistic importer.
struct ScheduledImport {
    let trackID: UUID
    let versionID: UUID
}

enum ImportPhase: Equatable {
    case queued
    case converting
    case waveform
    case finishing
    case complete
    case failed
    case cancelled
}

struct ImportActivityItem: Identifiable, Equatable {
    let id: UUID
    let filename: String
    var phase: ImportPhase
    var fraction: Double?
    var errorMessage: String?
}

@Observable
@MainActor
final class ImportCoordinator {

    // MARK: - Public State

    var isImporting = false
    var pendingImportCount = 0
    var importError: String?
    var importActivity: [ImportActivityItem] = []

    private struct ImportAttempt {
        let sourceURL: URL
        let outputURL: URL
        let trackID: UUID
        let versionID: UUID
        let selectedCoverArt: Data?
        let planningSourceHash: String
        let context: ModelContext
        let transferManager: TransferManager
    }

    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private var attempts: [UUID: ImportAttempt] = [:]
    private var attemptGenerations: [UUID: Int] = [:]
    private var cancelledAttemptIDs: Set<UUID> = []

    var aggregateImportFraction: Double {
        let total = max(importActivity.count, 1)
        let sum = importActivity.reduce(0.0) { partial, item in
            switch item.phase {
            case .complete, .failed, .cancelled, .waveform, .finishing:
                return partial + 1
            case .converting:
                return partial + (item.fraction ?? 0)
            case .queued:
                return partial
            }
        }
        return min(sum / Double(total), 1)
    }

    var remainingImportCount: Int {
        importActivity.filter {
            switch $0.phase {
            case .complete, .failed: return false
            case .cancelled: return false
            default: return true
            }
        }.count
    }

    var hasFailedImports: Bool {
        importActivity.contains { $0.phase == .failed }
    }

    var hasCancelledImports: Bool {
        importActivity.contains { $0.phase == .cancelled }
    }

    var isImportActivityVisible: Bool {
        !importActivity.isEmpty
    }

    var activeImportFilename: String? {
        importActivity.first(where: {
            switch $0.phase {
            case .converting, .waveform, .finishing, .queued: return true
            default: return false
            }
        })?.filename
    }

    var importActivityHelpText: String {
        if hasFailedImports && remainingImportCount == 0 {
            let failed = importActivity.filter { $0.phase == .failed }.count
            return failed == 1 ? "1 import failed — click for details" : "\(failed) imports failed — click for details"
        }
        if hasCancelledImports && remainingImportCount == 0 {
            let cancelled = importActivity.filter { $0.phase == .cancelled }.count
            return cancelled == 1 ? "1 import cancelled — click for details" : "\(cancelled) imports cancelled — click for details"
        }
        let remaining = remainingImportCount
        let total = importActivity.count
        let done = total - remaining
        let current = activeImportFilename ?? "files"
        if remaining == 0 {
            return "Import complete"
        }
        return "Importing \(done + 1) of \(total) — \(current)"
    }

    private let waveformProcessor = WaveformProcessor()
    /// Success toast message armed at commit; fired on clean batch drain.
    private var pendingSuccessMessage: String?
    private var toastCenter: FooterToastCenter?

    /// Hand a commit-time success message to emit when the batch actually finishes.
    func armSuccessToast(_ message: String, using toastCenter: FooterToastCenter) {
        pendingSuccessMessage = message
        self.toastCenter = toastCenter
    }

    func clearImportActivity() {
        guard remainingImportCount == 0, pendingImportCount == 0 else { return }
        pendingSuccessMessage = nil
        importActivity.removeAll()
        attempts.removeAll()
        cancelledAttemptIDs.removeAll()
        isImporting = false
    }

    private func upsertActivity(
        id: UUID,
        filename: String? = nil,
        phase: ImportPhase,
        fraction: Double? = nil,
        errorMessage: String? = nil
    ) {
        if let index = importActivity.firstIndex(where: { $0.id == id }) {
            importActivity[index].phase = phase
            importActivity[index].fraction = fraction
            importActivity[index].errorMessage = errorMessage
        } else if let filename {
            importActivity.append(
                ImportActivityItem(
                    id: id,
                    filename: filename,
                    phase: phase,
                    fraction: fraction,
                    errorMessage: errorMessage
                )
            )
        }
    }

    private func handleBatchDrainIfNeeded() {
        guard pendingImportCount == 0 else { return }
        isImporting = false

        if hasFailedImports {
            // Keep failed rows until the user clears them; no success toast.
            pendingSuccessMessage = nil
            importActivity.removeAll { $0.phase == .complete }
            return
        }

        if hasCancelledImports {
            pendingSuccessMessage = nil
            importActivity.removeAll { $0.phase == .complete }
            return
        }

        let message = pendingSuccessMessage
        pendingSuccessMessage = nil
        importActivity.removeAll()
        if let message {
            toastCenter?.show(.success, message)
        }
    }

    private func nextGeneration(for versionID: UUID) -> Int {
        let generation = (attemptGenerations[versionID] ?? 0) + 1
        attemptGenerations[versionID] = generation
        cancelledAttemptIDs.remove(versionID)
        return generation
    }

    private func isAttemptActive(_ versionID: UUID, generation: Int) -> Bool {
        !Task.isCancelled
            && attemptGenerations[versionID] == generation
            && !cancelledAttemptIDs.contains(versionID)
    }

    // MARK: - Import Planning

    func prepareImportPlan(_ urls: [URL], context: ModelContext) async -> ImportPlan {
        let tracks = (try? context.fetch(
            FetchDescriptor(
                sortBy: [
                    SortDescriptor(\Track.updatedAt, order: .reverse),
                    SortDescriptor(\Track.createdAt, order: .reverse)
                ]
            )
        )) ?? []

        let allVersions = (try? context.fetch(FetchDescriptor<Version>())) ?? []
        var knownHashes = Set(allVersions.compactMap(\.sourceContentHash))
        let durationsByTrack: [UUID: [TimeInterval]] = Dictionary(
            grouping: allVersions.filter { $0.duration > 0 },
            by: \.trackID
        ).mapValues { $0.map(\.duration) }

        let availableTracks: [ImportTrackOption] = tracks
            .map { track in
                ImportTrackOption(
                    id: track.id,
                    name: track.name,
                    workingTitle: track.workingTitle,
                    versionCount: track.versions.count,
                    updatedAt: track.updatedAt
                )
            }
            .sorted {
                if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        var items: [ImportPlanItem] = []
        for url in urls {
            let filename = url.lastPathComponent
            let parsed = ImportPlanning.parseImportTitle(from: filename)

            // Hash + duration off MainActor so multi-file WAV drops don't beachball
            // the UI while the review sheet is prepared.
            let (hash, sourceDuration) = await Self.hashAndDurationOffMain(url: url)
            let exactDuplicate = !hash.isEmpty && !knownHashes.insert(hash).inserted

            let matchKind = ImportPlanning.matchTracks(
                parsedTitle: parsed,
                tracks: tracks
            )

            // Near-duplicate check: compare source file's duration against any
            // existing version on the suggested Track. We use `displayCandidateID`
            // here (not `resolvedTrackID`) so ambiguous rows still surface the warning
            // against their first candidate — better signal than nothing.
            let nearDuplicate: Bool = {
                guard let targetID = matchKind.displayCandidateID,
                      let durations = durationsByTrack[targetID] else { return false }
                guard sourceDuration > 0 else { return false }
                return durations.contains { abs($0 - sourceDuration) < 0.5 }
            }()

            let metadata = await MetadataExtractor.extract(from: url)

            items.append(ImportPlanItem(
                sourceURL: url,
                originalTitle: parsed.originalTitle,
                originalFilename: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
                detectedTrackName: parsed.detectedTrackName,
                detectedVersionLabel: parsed.detectedVersionLabel,
                editableVersionLabel: parsed.hasDetectedVersion ? parsed.detectedVersionLabel : "",
                hasDetectedVersion: parsed.hasDetectedVersion,
                matchKind: matchKind,
                mixVsVersionAmbiguous: parsed.mixVsVersionAmbiguous,
                sourceContentHash: hash,
                isExactDuplicate: exactDuplicate,
                isNearDuplicate: nearDuplicate,
                sourceDuration: sourceDuration,
                skip: exactDuplicate,
                extractedArtwork: metadata.artwork
            ))
        }

        var groups = ImportPlanning.groupItems(items)
        for index in groups.indices {
            let suggestions = Set(groups[index].activeItems.compactMap {
                ImportPlanning.inferRecordingDate(from: $0.originalFilename)
            })
            let existingLabels: [String]
            if case .existingTrack(let trackID) = groups[index].target,
               let existingTrack = tracks.first(where: { $0.id == trackID }) {
                existingLabels = existingTrack.versions.map(\.label)
                // Show the persisted date for an existing track. A new filename
                // suggestion must not visually imply that importing another
                // version will replace established metadata.
                groups[index].recordingDateString = existingTrack.recordingDateString
                    ?? (suggestions.count == 1 ? suggestions.first : nil)
            } else {
                existingLabels = []
                groups[index].recordingDateString = suggestions.count == 1 ? suggestions.first : nil
            }
            ImportPlanning.prefillVersionLabels(in: &groups[index], existingLabels: existingLabels, style: .decimal)
        }
        return ImportPlan(availableTracks: availableTracks, groups: groups)
    }

    // MARK: - Optimistic Scheduling

    @discardableResult
    func scheduleImport(
        _ plan: ImportPlan,
        context: ModelContext,
        transferManager: TransferManager
    ) -> [ScheduledImport] {
        importError = nil
        var results: [ScheduledImport] = []
        for group in plan.groups {
            let active = group.activeItems
            guard !active.isEmpty else { continue }
            guard let track = resolveTrack(for: group, context: context) else { continue }
            // Plan-time Set decision is authoritative on Mac (review-sheet chip).
            if group.effectiveMarkAsSet {
                track.isSet = true
            }
            if group.recordingDateIsExplicit || (track.recordingDateString == nil && group.recordingDateString != nil) {
                track.setRecordingDate(group.recordingDateString)
            }
            var assignedLabels: Set<String> = []
            for item in active {
                if let scheduled = scheduleItem(
                    item: item,
                    onto: track,
                    coverArt: group.selectedCoverArt,
                    assignedLabels: &assignedLabels,
                    context: context,
                    transferManager: transferManager
                ) {
                    results.append(scheduled)
                }
            }
        }
        return results
    }

    /// Single-item fast path used by the high-confidence one-file import flow. The caller
    /// already knows which group/track this lands on; we just need to mint the placeholder
    /// rows and kick off background processing.
    @discardableResult
    func scheduleSingle(
        group: ImportPlanGroup,
        context: ModelContext,
        transferManager: TransferManager
    ) -> ScheduledImport? {
        guard let item = group.activeItems.first else { return nil }
        guard let track = resolveTrack(for: group, context: context) else { return nil }
        if group.effectiveMarkAsSet {
            track.isSet = true
        }
        if group.recordingDateIsExplicit || (track.recordingDateString == nil && group.recordingDateString != nil) {
            track.setRecordingDate(group.recordingDateString)
        }
        var assignedLabels: Set<String> = []
        return scheduleItem(
            item: item,
            onto: track,
            coverArt: group.selectedCoverArt,
            assignedLabels: &assignedLabels,
            context: context,
            transferManager: transferManager
        )
    }

    private func scheduleItem(
        item: ImportPlanItem,
        onto track: Track,
        coverArt: Data?,
        assignedLabels: inout Set<String>,
        context: ModelContext,
        transferManager: TransferManager
    ) -> ScheduledImport? {
        let audioDir = Self.audioDirectory()
        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        } catch {
            importError = "Could not create storage directory: \(error.localizedDescription)"
            return nil
        }

        let isNewTrack = track.versions.isEmpty
        let outputID = UUID()
        let outputURL = audioDir.appendingPathComponent("\(outputID.uuidString).m4a")
        let versionLabel = resolveVersionLabel(for: item, track: track, alsoAvoiding: assignedLabels)
        assignedLabels.insert(versionLabel.lowercased())

        let version = Version(
            id: outputID,
            trackID: track.id,
            label: versionLabel,
            filePath: outputURL.path,
            fileSize: 0,
            fileFormat: "m4a",
            originalFilename: item.sourceURL.lastPathComponent,
            duration: 0,
            waveformData: nil,
            contentHash: "",
            sourceContentHash: item.sourceContentHash.isEmpty ? nil : item.sourceContentHash,
            mixNumber: ImportPlanning.parseMixNumber(from: item.originalFilename),
            processingState: .pending
        )

        track.versions.append(version)
        track.updatedAt = .now
        track.lastTouchedAt = .now
        if isNewTrack { track.processingState = .pending }
        context.insert(version)

        do {
            try context.save()
        } catch {
            SyncLog.importer.error("save failed at scheduling: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        pendingImportCount += 1
        isImporting = true
        upsertActivity(
            id: version.id,
            filename: item.sourceURL.lastPathComponent,
            phase: .queued
        )

        let attempt = ImportAttempt(
            sourceURL: item.sourceURL,
            outputURL: outputURL,
            trackID: track.id,
            versionID: version.id,
            selectedCoverArt: coverArt,
            planningSourceHash: item.sourceContentHash,
            context: context,
            transferManager: transferManager
        )
        attempts[version.id] = attempt
        let generation = nextGeneration(for: version.id)
        processingTasks[version.id] = Task { [weak self] in
            guard let self else { return }
            await self.processInBackground(attempt: attempt, generation: generation)
        }

        return ScheduledImport(trackID: track.id, versionID: version.id)
    }

    /// Stops one unfinished item and removes only the optimistic rows/files
    /// owned by that attempt. Completed siblings in a batch are untouched.
    func cancelImport(versionID: UUID) {
        guard let item = importActivity.first(where: { $0.id == versionID }) else { return }
        switch item.phase {
        case .queued, .converting, .waveform, .finishing:
            break
        default:
            return
        }

        cancelledAttemptIDs.insert(versionID)
        attemptGenerations[versionID, default: 0] += 1
        processingTasks[versionID]?.cancel()
        upsertActivity(
            id: versionID,
            phase: .cancelled,
            fraction: nil,
            errorMessage: "Cancelled"
        )
        cleanupCancelledAttempt(versionID: versionID)
    }

    /// Retries only one failed item, retaining its reviewed metadata and
    /// version identity. If the security-scoped source is gone, stop with an
    /// actionable re-import message instead of looping forever.
    func retryImport(versionID: UUID) {
        guard let item = importActivity.first(where: { $0.id == versionID }),
              item.phase == .failed,
              let attempt = attempts[versionID] else { return }
        guard FileManager.default.fileExists(atPath: attempt.sourceURL.path) else {
            upsertActivity(
                id: versionID,
                phase: .failed,
                fraction: nil,
                errorMessage: "Source file is unavailable. Re-import it to choose the file again."
            )
            return
        }

        try? FileManager.default.removeItem(at: attempt.outputURL)
        if let version = attempt.context.fetchByID(Version.self, id: versionID) {
            version.processingState = .pending
        }
        if let track = attempt.context.fetchByID(Track.self, id: attempt.trackID),
           track.processingState == .failed {
            track.processingState = .pending
        }
        try? attempt.context.save()

        let generation = nextGeneration(for: versionID)
        pendingImportCount += 1
        isImporting = true
        upsertActivity(id: versionID, phase: .queued, fraction: nil)
        processingTasks[versionID] = Task { [weak self] in
            guard let self else { return }
            await self.processInBackground(attempt: attempt, generation: generation)
        }
    }

    func cancelAllImports() {
        let activeIDs = importActivity.compactMap { item in
            switch item.phase {
            case .queued, .converting, .waveform, .finishing: return item.id
            default: return nil
            }
        }
        for id in activeIDs { cancelImport(versionID: id) }
    }

    private func cleanupCancelledAttempt(versionID: UUID) {
        guard let attempt = attempts[versionID] else { return }
        try? FileManager.default.removeItem(at: attempt.outputURL)
        guard let version = attempt.context.fetchByID(Version.self, id: versionID) else { return }
        let track = attempt.context.fetchByID(Track.self, id: attempt.trackID)
        attempt.context.delete(version)
        if let track, track.versions.isEmpty {
            attempt.context.delete(track)
        }
        try? attempt.context.save()
    }

    // MARK: - Background Processing

    private func processInBackground(attempt: ImportAttempt, generation: Int) async {
        let sourceURL = attempt.sourceURL
        let outputURL = attempt.outputURL
        let trackID = attempt.trackID
        let versionID = attempt.versionID
        let selectedCoverArt = attempt.selectedCoverArt
        let planningSourceHash = attempt.planningSourceHash
        let context = attempt.context
        let transferManager = attempt.transferManager

        defer {
            if attemptGenerations[versionID] == generation {
                processingTasks.removeValue(forKey: versionID)
            }
            pendingImportCount = max(0, pendingImportCount - 1)
            handleBatchDrainIfNeeded()
        }

        guard isAttemptActive(versionID, generation: generation) else { return }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            markFailed(
                versionID: versionID,
                trackID: trackID,
                context: context,
                message: "Source file is unavailable. Re-import it to choose the file again."
            )
            return
        }

        // NSOpenPanel URLs come with a security scope (returns true).
        // Drag-and-drop URLs in an unsandboxed Mac app don't (returns false) —
        // but the file is still readable directly. Don't gate on the call;
        // just balance start/stop if it actually started.
        let didStartScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let filename = sourceURL.lastPathComponent

        let fileCreationDate: Date = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
               let date = attrs[.creationDate] as? Date {
                return date
            }
            return Date()
        }()

        async let durationTask = Self.audioDuration(url: sourceURL)
        async let metadataTask = MetadataExtractor.extract(from: sourceURL)
        let duration = await durationTask
        let metadata = await metadataTask

        guard isAttemptActive(versionID, generation: generation) else { return }

        upsertActivity(id: versionID, phase: .converting, fraction: 0)

        do {
            try await Self.exportAAC(from: sourceURL, to: outputURL) { [weak self] fraction in
                Task { @MainActor in
                    self?.upsertActivity(id: versionID, phase: .converting, fraction: fraction)
                }
            }
        } catch {
            guard isAttemptActive(versionID, generation: generation) else {
                try? FileManager.default.removeItem(at: outputURL)
                return
            }
            SyncLog.importer.error("AAC export failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            do {
                try FileManager.default.copyItem(at: sourceURL, to: outputURL)
            } catch {
                SyncLog.importer.error("copy fallback failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                markFailed(
                    versionID: versionID,
                    trackID: trackID,
                    context: context,
                    message: "Could not process \(filename): \(error.localizedDescription)"
                )
                return
            }
        }

        guard isAttemptActive(versionID, generation: generation) else {
            try? FileManager.default.removeItem(at: outputURL)
            return
        }
        upsertActivity(id: versionID, phase: .waveform, fraction: nil)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let waveformData = try? await waveformProcessor.process(fileURL: outputURL)

        guard isAttemptActive(versionID, generation: generation) else {
            try? FileManager.default.removeItem(at: outputURL)
            return
        }
        upsertActivity(id: versionID, phase: .finishing, fraction: nil)

        guard let version = context.fetchByID(Version.self, id: versionID),
              let track = context.fetchByID(Track.self, id: trackID) else {
            SyncLog.importer.error("could not find scheduled rows on completion for \(filename, privacy: .public)")
            try? FileManager.default.removeItem(at: outputURL)
            upsertActivity(
                id: versionID,
                phase: .failed,
                fraction: nil,
                errorMessage: "The scheduled import record disappeared. Re-import the file."
            )
            return
        }

        guard isAttemptActive(versionID, generation: generation) else {
            try? FileManager.default.removeItem(at: outputURL)
            return
        }

        version.duration = duration
        version.fileSize = fileSize
        version.waveformData = waveformData
        version.processingState = .complete
        version.addedAt = fileCreationDate
        // Stream-hash the encoded output off MainActor; reuse planning-time source hash
        // so we never re-read the original WAV on completion.
        let encodedHash = await Task.detached {
            (try? FileIntegrity.sha256Hex(for: outputURL)) ?? ""
        }.value
        guard isAttemptActive(versionID, generation: generation) else {
            try? FileManager.default.removeItem(at: outputURL)
            return
        }
        version.contentHash = encodedHash
        version.sourceContentHash = planningSourceHash.isEmpty ? nil : planningSourceHash

        if let selectedCoverArt {
            track.setArtwork(selectedCoverArt)
        }
        applyMetadata(metadata, to: track)
        track.updatedAt = .now
        track.lastTouchedAt = max(track.lastTouchedAt, fileCreationDate)
        if track.processingState == .pending {
            track.processingState = .complete
        }

        do {
            try context.save()
        } catch {
            SyncLog.importer.error("save failed on completion: \(error.localizedDescription, privacy: .public)")
            markFailed(
                versionID: versionID,
                trackID: trackID,
                context: context,
                message: "Could not save \(filename): \(error.localizedDescription)"
            )
            return
        }

        upsertActivity(id: versionID, phase: .complete, fraction: 1)
        transferManager.queueVersion(version)
        attempts.removeValue(forKey: versionID)
    }

    private func markFailed(versionID: UUID, trackID: UUID, context: ModelContext, message: String) {
        if let version = context.fetchByID(Version.self, id: versionID) {
            version.processingState = .failed
        }
        if let track = context.fetchByID(Track.self, id: trackID),
           track.versions.allSatisfy({ $0.processingState != .complete }) {
            track.processingState = .failed
        }
        try? context.save()
        upsertActivity(id: versionID, phase: .failed, fraction: nil, errorMessage: message)
    }

    // MARK: - SwiftData Helpers

    private func resolveTrack(for group: ImportPlanGroup, context: ModelContext) -> Track? {
        switch group.target {
        case .existingTrack(let id):
            return findTrack(id: id, context: context)
        case .newTrack:
            let fallback = group.items.first?.originalTitle ?? "Untitled"
            let name = group.editableTrackName.isEmpty ? fallback : group.editableTrackName
            return findOrCreateTrack(named: name, context: context)
        case .unresolved:
            SyncLog.importer.error("attempted to resolve unresolved group")
            return nil
        }
    }

    private func applyMetadata(_ metadata: TrackMetadata, to track: Track) {
        if track.artist.isEmpty, let artist = metadata.artist {
            track.artist = artist
        }
        if track.artwork == nil, let artwork = metadata.artwork {
            track.setArtwork(artwork)
        }
        if track.bpm == nil, let bpm = metadata.bpm {
            track.bpm = bpm
        }
    }

    private func resolveVersionLabel(for item: ImportPlanItem, track: Track, alsoAvoiding: Set<String>) -> String {
        let preferred = item.editableVersionLabel.isEmpty == false
            ? item.editableVersionLabel
            : (item.hasDetectedVersion ? item.detectedVersionLabel : nil)
        return makeVersionLabel(preferred: preferred, for: track, alsoAvoiding: alsoAvoiding)
    }

    private func findTrack(id: UUID, context: ModelContext) -> Track? {
        context.fetchByID(Track.self, id: id)
    }

    private func findOrCreateTrack(named name: String, context: ModelContext) -> Track {
        let lower = name.lowercased()
        if let existing = try? context.fetch(FetchDescriptor<Track>()).first(where: { $0.name.lowercased() == lower }) {
            return existing
        }
        let track = Track(name: name, origin: .mac)
        context.insert(track)
        return track
    }

    private func makeVersionLabel(preferred: String?, for track: Track, alsoAvoiding: Set<String> = []) -> String {
        let taken = Set(track.versions.map { $0.label.lowercased() }).union(alsoAvoiding)

        if let preferred {
            let lower = preferred.lowercased()
            if !taken.contains(lower) { return preferred }
            // Same-batch collision: disambiguate by appending (2), (3) ... rather than
            // overwriting the user-provided label with a generic vN.
            var n = 2
            while taken.contains("\(preferred) (\(n))".lowercased()) { n += 1 }
            return "\(preferred) (\(n))"
        }

        return ImportPlanning.defaultVersionLabel(
            style: .decimal,
            taken: taken,
            versionCount: track.versions.count + alsoAvoiding.count
        )
    }

    // MARK: - Audio Utilities

    /// Streaming SHA + async duration, always off MainActor (ImportCoordinator is @MainActor).
    nonisolated private static func hashAndDurationOffMain(url: URL) async -> (String, TimeInterval) {
        await Task.detached(priority: .userInitiated) {
            let hash = ImportPlanning.fileContentHash(at: url) ?? ""
            let duration = await ImportPlanning.fileDuration(at: url)
            return (hash, duration)
        }.value
    }

    nonisolated static func audioDuration(url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            if seconds <= 0 {
                SyncLog.importer.warning("audioDuration returned \(seconds) for \(url.lastPathComponent, privacy: .public)")
            }
            return seconds
        } catch {
            SyncLog.importer.error("audioDuration failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    nonisolated static func exportAAC(
        from sourceURL: URL,
        to destinationURL: URL,
        onProgress: (@Sendable (Double?) -> Void)? = nil
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.exportSessionCreationFailed
        }

        let progressTask = Task {
            for await state in session.states(updateInterval: 0.5) {
                if case .exporting(let progress) = state {
                    let fraction = progress.fractionCompleted
                    if fraction.isFinite, fraction >= 0 {
                        onProgress?(min(max(fraction, 0), 1))
                    } else {
                        onProgress?(nil)
                    }
                }
            }
        }
        defer { progressTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await session.export(to: destinationURL, as: .m4a)
            } onCancel: {
                session.cancelExport()
            }
        } catch is CancellationError {
            throw ImportError.exportFailed("cancelled")
        }
        if Task.isCancelled {
            session.cancelExport()
            throw ImportError.exportFailed("cancelled")
        }
    }

    nonisolated static func audioDirectory() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return appSupport.appendingPathComponent("\(BounceConstants.applicationSupportDirectoryName)/audio/")
    }
}

// MARK: - Errors

enum ImportError: LocalizedError {
    case exportSessionCreationFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .exportSessionCreationFailed:
            return "Failed to create AVAssetExportSession"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        }
    }
}
