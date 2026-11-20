import Foundation
import SwiftData
import AVFoundation
import BounceKit

/// Coordinates importing audio files on iOS — from document picker or share sheet.
/// Processes files locally (copy + waveform), creates Track/Version with `.phone` origin.
@Observable
@MainActor
final class iOSImportCoordinator {

    // MARK: - Public State

    var isImporting = false
    var importError: String?
    var importedCount: Int = 0

    /// Set when a file is picked and ready for user review. iOS always reviews a single file
    /// at a time, so the group always contains exactly one item.
    var reviewGroup: ImportPlanGroup?
    /// Tracks available for target selection during review.
    var reviewAvailableTracks: [ImportTrackOption] = []

    private var reviewSourceURL: URL?
    private let waveformProcessor = WaveformProcessor()

    // MARK: - Review Flow

    /// Begin the import review flow for a single file. Parses the filename, runs the
    /// matcher against the library, and populates `reviewItem` for presentation.
    func beginImportReview(for url: URL, context: ModelContext) async {
        isImporting = true
        defer { isImporting = false }
        importError = nil

        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let allVersions = (try? context.fetch(FetchDescriptor<Version>())) ?? []
        let existingHashes = Set(allVersions.compactMap(\.sourceContentHash))
        let durationsByTrack: [UUID: [TimeInterval]] = Dictionary(
            grouping: allVersions.filter { $0.duration > 0 },
            by: \.trackID
        ).mapValues { $0.map(\.duration) }

        let filename = url.lastPathComponent
        let parsed = ImportPlanning.parseImportTitle(from: filename)
        let hash = await Task.detached(priority: .userInitiated) {
            ImportPlanning.fileContentHash(at: url) ?? ""
        }.value
        let exactDuplicate = !hash.isEmpty && existingHashes.contains(hash)

        let matchKind = ImportPlanning.matchTracks(
            parsedTitle: parsed,
            tracks: tracks
        )

        let sourceDuration = ImportPlanning.fileDurationSync(at: url)
        let nearDuplicate: Bool = {
            guard let targetID = matchKind.displayCandidateID,
                  let durations = durationsByTrack[targetID] else { return false }
            guard sourceDuration > 0 else { return false }
            return durations.contains { abs($0 - sourceDuration) < 0.5 }
        }()

        let availableTracks = tracks
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

        let item = ImportPlanItem(
            sourceURL: url,
            originalTitle: parsed.originalTitle,
            originalFilename: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
            detectedTrackName: parsed.detectedTrackName,
            detectedVersionLabel: parsed.detectedVersionLabel,
            editableVersionLabel: parsed.detectedVersionLabel,
            hasDetectedVersion: parsed.hasDetectedVersion,
            matchKind: matchKind,
            mixVsVersionAmbiguous: parsed.mixVsVersionAmbiguous,
            sourceContentHash: hash,
            isExactDuplicate: exactDuplicate,
            isNearDuplicate: nearDuplicate,
            skip: exactDuplicate
        )

        // Run the same grouper the Mac uses so iOS gets a 1-group plan with the right target.
        var group = ImportPlanning.groupItems([item]).first ?? ImportPlanGroup(
            target: .newTrack,
            editableTrackName: parsed.detectedTrackName,
            items: [item]
        )
        let existingLabels: [String]
        if case .existingTrack(let trackID) = group.target,
           let existingTrack = tracks.first(where: { $0.id == trackID }) {
            existingLabels = existingTrack.versions.map(\.label)
            group.recordingDateString = existingTrack.recordingDateString
                ?? ImportPlanning.inferRecordingDate(from: filename)
        } else {
            existingLabels = []
            group.recordingDateString = ImportPlanning.inferRecordingDate(from: filename)
        }
        ImportPlanning.prefillVersionLabels(in: &group, existingLabels: existingLabels, style: .prefixed)

        self.reviewAvailableTracks = availableTracks
        self.reviewGroup = group
        self.reviewSourceURL = url
    }

    /// Cancel the current review and clean up the temp file.
    func cancelImport() {
        if let url = reviewSourceURL {
            try? FileManager.default.removeItem(at: url)
        }
        reviewGroup = nil
        reviewAvailableTracks = []
        reviewSourceURL = nil
    }

    /// Confirm import with the user's edited choices. Copies the file, creates
    /// SwiftData rows, and schedules an upload.
    func confirmImport(group: ImportPlanGroup, context: ModelContext) async {
        guard let item = group.items.first, !item.skip else {
            cleanUp()
            return
        }
        isImporting = true
        defer { isImporting = false }

        let audioDir = Self.audioDirectory()
        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        } catch {
            importError = "Could not create storage directory: \(error.localizedDescription)"
            cleanUp()
            return
        }

        let url = item.sourceURL
        let needsSecurityScope = url.startAccessingSecurityScopedResource()
        defer { if needsSecurityScope { url.stopAccessingSecurityScopedResource() } }

        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let outputID = UUID()
        let outputURL = audioDir.appendingPathComponent("\(outputID.uuidString).\(ext)")

        let duration = await Self.audioDuration(url: url)

        // Try AAC export for non-m4a; fall back to copy
        let finalURL: URL
        let finalFormat: String
        if ext != "m4a" {
            let aacURL = audioDir.appendingPathComponent("\(outputID.uuidString).m4a")
            do {
                try await Self.exportAAC(from: url, to: aacURL)
                finalURL = aacURL
                finalFormat = "m4a"
            } catch {
                do {
                    try FileManager.default.copyItem(at: url, to: outputURL)
                    finalURL = outputURL
                    finalFormat = Self.fileFormat(for: ext)
                } catch {
                    importError = "Failed to copy \(filename): \(error.localizedDescription)"
                    cleanUp()
                    return
                }
            }
        } else {
            do {
                try FileManager.default.copyItem(at: url, to: outputURL)
                finalURL = outputURL
                finalFormat = "m4a"
            } catch {
                importError = "Failed to copy \(filename): \(error.localizedDescription)"
                cleanUp()
                return
            }
        }

        // Determine track and version label
        let track: Track
        let versionLabel: String
        let isNewTrack: Bool
        switch group.target {
        case .existingTrack(let trackID):
            guard let existingTrack = (try? context.fetch(FetchDescriptor<Track>()))?.first(where: { $0.id == trackID }) else {
                importError = "Selected track not found"
                try? FileManager.default.removeItem(at: finalURL)
                cleanUp()
                return
            }
            track = existingTrack
            isNewTrack = track.versions.isEmpty
            let preferred = item.editableVersionLabel.isEmpty == false
                ? item.editableVersionLabel
                : (item.hasDetectedVersion ? item.detectedVersionLabel : nil)
            versionLabel = Self.makeVersionLabel(preferred: preferred, for: track)
        case .newTrack:
            let trackName = group.editableTrackName.isEmpty ? item.originalTitle : group.editableTrackName
            track = Track(name: trackName, origin: .phone)
            isNewTrack = true
            context.insert(track)
            versionLabel = ImportPlanning.defaultVersionLabel(style: .prefixed, taken: [], versionCount: 0)
            if let cover = group.selectedCoverArt {
                track.setArtwork(cover)
            }
        case .unresolved:
            importError = "Pick a target track"
            try? FileManager.default.removeItem(at: finalURL)
            cleanUp()
            return
        }

        if group.recordingDateIsExplicit || (track.recordingDateString == nil && group.recordingDateString != nil) {
            track.setRecordingDate(group.recordingDateString)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        let fileCreationDate: Date = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
               let date = attrs[.creationDate] as? Date {
                return date
            }
            return Date()
        }()

        let waveformData = try? await waveformProcessor.process(fileURL: finalURL)
        let outputContentHash = await Task.detached(priority: .userInitiated) {
            (try? FileIntegrity.sha256Hex(for: finalURL)) ?? ""
        }.value

        let version = Version(
            trackID: track.id,
            label: versionLabel,
            filePath: finalURL.path,
            fileSize: fileSize,
            fileFormat: finalFormat,
            originalFilename: filename,
            duration: duration,
            waveformData: waveformData
        )
        version.addedAt = fileCreationDate
        version.contentHash = outputContentHash
        version.sourceContentHash = item.sourceContentHash.isEmpty ? nil : item.sourceContentHash
        track.versions.append(version)
        if isNewTrack && UserDefaults.standard.bool(forKey: BouncePreferenceKey.showSetsTab) && duration >= BounceConstants.setAutoTagDurationThreshold {
            track.isSet = true
        }
        track.updatedAt = .now
        track.lastTouchedAt = max(track.lastTouchedAt, fileCreationDate)
        context.insert(version)

        // Create pending upload entry for Mac sync
        let pendingUpload = PendingUpload(
            versionID: version.id,
            trackID: track.id,
            trackName: track.name,
            filePath: finalURL.path,
            fileSize: fileSize,
            fileFormat: finalFormat,
            originalFilename: filename,
            duration: duration,
            versionLabel: versionLabel,
            targetTrackID: group.target.resolvedTrackID,
            sourceContentHash: version.sourceContentHash
        )
        context.insert(pendingUpload)

        do {
            try context.save()
            importedCount += 1
            print("[iOSImport] saved: \(track.name) [\(versionLabel)] → \(finalURL.lastPathComponent)")
        } catch {
            importError = "Save failed: \(error.localizedDescription)"
            print("[iOSImport] ERROR: save failed: \(error.localizedDescription)")
            // The audio copy and optimistic rows belong to this attempt. Do
            // not leave an orphaned playable file or ghost catalog entry when
            // SwiftData rejects the save.
            try? FileManager.default.removeItem(at: finalURL)
            let shouldDeleteTrack = isNewTrack && track.versions.count <= 1
            context.delete(pendingUpload)
            context.delete(version)
            if shouldDeleteTrack {
                context.delete(track)
            }
            try? context.save()
            cleanUp()
            return
        }

        // Give SwiftData's @Query observers a tick to surface the new row
        // before the defer flips isImporting=false. Without this yield, the
        // spinner disappears one frame ahead of the new track row showing up
        // and the empty state briefly flashes without any indicator (#75).
        await Task.yield()

        cleanUp()
    }

    // MARK: - Private Helpers

    private func cleanUp() {
        if let url = reviewSourceURL {
            try? FileManager.default.removeItem(at: url)
        }
        reviewGroup = nil
        reviewAvailableTracks = []
        reviewSourceURL = nil
    }

    private static func makeVersionLabel(preferred: String?, for track: Track) -> String {
        let existingLabels = Set(track.versions.map { $0.label.lowercased() })

        if let preferred, existingLabels.contains(preferred.lowercased()) == false {
            return preferred
        }

        return ImportPlanning.defaultVersionLabel(
            style: .prefixed,
            taken: existingLabels,
            versionCount: track.versions.count
        )
    }

    // MARK: - Audio Utilities

    nonisolated static func audioDuration(url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            return 0
        }
    }

    nonisolated static func exportAAC(from sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.exportSessionCreationFailed
        }
        session.outputURL = destinationURL
        session.outputFileType = .m4a

        await session.export()

        switch session.status {
        case .completed:
            return
        case .failed:
            throw session.error ?? ImportError.exportFailed("unknown")
        case .cancelled:
            throw ImportError.exportFailed("cancelled")
        default:
            throw ImportError.exportFailed("status: \(session.status.rawValue)")
        }
    }

    nonisolated static func audioDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Bounce/audio/", isDirectory: true)
    }

    nonisolated private static func fileFormat(for ext: String) -> String {
        switch ext {
        case "mp3": return "mp3"
        case "wav": return "wav"
        case "aif", "aiff": return "aiff"
        case "m4a": return "m4a"
        case "flac": return "flac"
        default: return ext
        }
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
