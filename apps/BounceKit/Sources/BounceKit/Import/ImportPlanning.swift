import AVFoundation
import Foundation

// MARK: - Types

/// Where a group's items will land. `unresolved` is reserved for ambiguous matcher results
/// where the importer must force the user to pick before commit.
public enum ImportPlanGroupTarget: Equatable {
    case newTrack
    case existingTrack(UUID)
    /// Ambiguous matcher result. UI must show a target picker; commit is gated.
    case unresolved

    public var resolvedTrackID: UUID? {
        if case let .existingTrack(id) = self { return id }
        return nil
    }

    public var isNewTrack: Bool {
        if case .newTrack = self { return true }
        return false
    }

    public var isUnresolved: Bool {
        if case .unresolved = self { return true }
        return false
    }
}

/// Why the matcher picked a target Track. Replaces the prior similarity-score path.
public enum MatchKind: Equatable {
    case workingTitlePrefix(UUID)
    case dateStem(UUID)
    case ambiguous([UUID]) // matched multiple sibling Tracks by working title
    case none

    /// The single track this match resolves to, if unambiguous. Ambiguous
    /// matches return nil so the importer forces the user to disambiguate.
    public var resolvedTrackID: UUID? {
        switch self {
        case .workingTitlePrefix(let id), .dateStem(let id): return id
        case .ambiguous, .none: return nil
        }
    }

    /// First plausible candidate, used purely for UI display ("Suggested target: …").
    /// Do NOT use as the import target — use `resolvedTrackID` for that.
    public var displayCandidateID: UUID? {
        switch self {
        case .workingTitlePrefix(let id), .dateStem(let id): return id
        case .ambiguous(let ids): return ids.first
        case .none: return nil
        }
    }
}

public struct ImportTrackOption: Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let workingTitle: String?
    public let versionCount: Int
    public let updatedAt: Date

    public var menuLabel: String {
        let label = versionCount == 1 ? "1 mix" : "\(versionCount) mixes"
        let display = workingTitle?.isEmpty == false ? workingTitle! : name
        return "\(display) · \(label)"
    }

    public init(id: UUID, name: String, workingTitle: String?, versionCount: Int, updatedAt: Date) {
        self.id = id
        self.name = name
        self.workingTitle = workingTitle
        self.versionCount = versionCount
        self.updatedAt = updatedAt
    }
}

public struct ImportPlan: Identifiable {
    public let id = UUID()
    public let availableTracks: [ImportTrackOption]
    public var groups: [ImportPlanGroup]

    public var allItems: [ImportPlanItem] {
        groups.flatMap(\.items)
    }

    public var hasUnresolvedSelections: Bool {
        groups.contains { $0.target.isUnresolved && !$0.activeItems.isEmpty }
    }

    public init(availableTracks: [ImportTrackOption], groups: [ImportPlanGroup]) {
        self.availableTracks = availableTracks
        self.groups = groups
    }

    // MARK: - Mutations

    /// Split an item out of its current group into a fresh single-row `.newTrack` group.
    /// The new group inherits the item's detected track name and extracted artwork. If the
    /// source group becomes empty, it's removed.
    public mutating func splitItem(itemID: UUID) {
        guard let (groupIndex, itemIndex) = locate(itemID: itemID) else { return }
        let item = groups[groupIndex].items.remove(at: itemIndex)
        let newGroup = ImportPlanGroup(
            target: .newTrack,
            editableTrackName: item.detectedTrackName,
            extractedArtwork: item.extractedArtwork,
            items: [item]
        )
        if groups[groupIndex].items.isEmpty {
            groups.remove(at: groupIndex)
            groups.append(newGroup)
        } else {
            groups.insert(newGroup, at: groupIndex + 1)
        }
    }

    /// Move an item from its current group to another existing group. If the source group
    /// becomes empty after the move, it's removed.
    public mutating func moveItem(itemID: UUID, toGroupID: UUID) {
        guard let (sourceIndex, itemIndex) = locate(itemID: itemID),
              let destIndex = groups.firstIndex(where: { $0.id == toGroupID }),
              destIndex != sourceIndex else { return }
        let item = groups[sourceIndex].items.remove(at: itemIndex)
        groups[destIndex].items.append(item)
        if groups[destIndex].extractedArtwork == nil {
            groups[destIndex].extractedArtwork = item.extractedArtwork
        }
        if groups[sourceIndex].items.isEmpty {
            groups.remove(at: sourceIndex)
        }
    }

    /// Fold every item in `sourceID` into `targetID`, then drop the source group.
    /// Used when the matcher mis-grouped sibling files (e.g. 3 versions → 2 + 1) and the
    /// user wants to recover from the picker without doing per-file moves.
    public mutating func mergeGroup(sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID,
              let sourceIndex = groups.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = groups.firstIndex(where: { $0.id == targetID }) else { return }
        let movedItems = groups[sourceIndex].items
        if groups[targetIndex].extractedArtwork == nil {
            groups[targetIndex].extractedArtwork = groups[sourceIndex].extractedArtwork
        }
        groups[targetIndex].items.append(contentsOf: movedItems)
        groups.remove(at: sourceIndex)
    }

    private func locate(itemID: UUID) -> (group: Int, item: Int)? {
        for (g, group) in groups.enumerated() {
            if let i = group.items.firstIndex(where: { $0.id == itemID }) {
                return (g, i)
            }
        }
        return nil
    }
}

/// A unit of import: one target Track (existing or new) plus the source files that should
/// land on it as Versions. Groups are how the review sheet expresses "these files all
/// belong to the same track" — created up-front by the matcher and editable in the UI.
public struct ImportPlanGroup: Identifiable {
    public let id: UUID
    public var target: ImportPlanGroupTarget
    /// Used when target == .newTrack. Pre-filled from the first item's detected name (or
    /// the shared `cleanedBaseName` once batch grouping kicks in).
    public var editableTrackName: String
    /// Cover art extracted from the first item's metadata during planning.
    public var extractedArtwork: Data?
    /// User-selected cover art (overrides extractedArtwork when set).
    public var selectedCoverArt: Data?
    /// Explicit Set choice from the review sheet. `nil` means "use default when qualifying".
    public var markAsSet: Bool?
    /// Suggested or manually chosen recording day. The explicit flag lets the
    /// user clear an inferred date without it being re-inferred at commit.
    public var recordingDateString: String?
    public var recordingDateIsExplicit: Bool
    public var items: [ImportPlanItem]

    public var isNewTrack: Bool { target.isNewTrack }
    public var activeItems: [ImportPlanItem] { items.filter { !$0.skip } }

    /// Long first import onto a new track — show the Set chip and default it on.
    public var qualifiesAsSetSuggestion: Bool {
        guard isNewTrack else { return false }
        return activeItems.contains {
            $0.sourceDuration >= BounceConstants.setAutoTagDurationThreshold
        }
    }

    /// Effective Set tag to apply at commit. Never mutates existing-track groups.
    /// An explicit review-sheet choice wins; otherwise long imports default on.
    public var effectiveMarkAsSet: Bool {
        isNewTrack ? (markAsSet ?? qualifiesAsSetSuggestion) : false
    }

    public init(
        id: UUID = UUID(),
        target: ImportPlanGroupTarget,
        editableTrackName: String,
        extractedArtwork: Data? = nil,
        selectedCoverArt: Data? = nil,
        markAsSet: Bool? = nil,
        recordingDateString: String? = nil,
        recordingDateIsExplicit: Bool = false,
        items: [ImportPlanItem]
    ) {
        self.id = id
        self.target = target
        self.editableTrackName = editableTrackName
        self.extractedArtwork = extractedArtwork
        self.selectedCoverArt = selectedCoverArt
        self.markAsSet = markAsSet
        self.recordingDateString = RecordingDate.validate(recordingDateString)
        self.recordingDateIsExplicit = recordingDateIsExplicit
        self.items = items
    }
}

public struct ImportPlanItem: Identifiable {
    public let id: UUID
    public let sourceURL: URL
    public let originalTitle: String
    public let originalFilename: String
    public let detectedTrackName: String
    public let detectedVersionLabel: String
    public var editableVersionLabel: String
    public let hasDetectedVersion: Bool

    /// How (or whether) the matcher tied this file to an existing Track.
    public let matchKind: MatchKind

    /// True when filename suffix is ambiguous between mix and version (`_final2`, `_alt2`).
    /// Default behavior treats it as a new mix; UI exposes a toggle to override.
    public let mixVsVersionAmbiguous: Bool

    /// Audio hash of the source file. Used for exact-duplicate detection.
    public let sourceContentHash: String

    /// True when sourceContentHash matches an existing Version in the library.
    public let isExactDuplicate: Bool

    /// True when a Version with matching duration (± 0.5s) already exists for the suggested Track.
    public let isNearDuplicate: Bool

    /// Source-file duration measured during planning. Used for near-duplicate checks and Set suggestion.
    public let sourceDuration: TimeInterval

    /// User excluded this row from import (or it was an exact duplicate at planning time).
    public var skip: Bool

    /// Cover art extracted from the source file's metadata during planning. Stored on the
    /// item so the planner can promote one item's artwork onto the group it lands in.
    public let extractedArtwork: Data?

    /// Computed convenience: matcher found a target with no caveats, single-row plan can fast-path.
    public var isHighConfidence: Bool {
        guard !isExactDuplicate, !isNearDuplicate, !mixVsVersionAmbiguous else { return false }
        switch matchKind {
        case .workingTitlePrefix, .dateStem: return true
        case .ambiguous, .none: return false
        }
    }

    /// Human-readable explanation of the matcher decision (shown in review sheet).
    public var matchExplanation: String {
        if isExactDuplicate { return "Already in library" }
        switch matchKind {
        case .workingTitlePrefix: return "Matched by working title"
        case .dateStem: return "Matched by date stem"
        case .ambiguous(let ids): return "Multiple matches (\(ids.count))"
        case .none: return "New track"
        }
    }

    public init(
        sourceURL: URL,
        originalTitle: String,
        originalFilename: String,
        detectedTrackName: String,
        detectedVersionLabel: String,
        editableVersionLabel: String,
        hasDetectedVersion: Bool,
        matchKind: MatchKind,
        mixVsVersionAmbiguous: Bool,
        sourceContentHash: String,
        isExactDuplicate: Bool,
        isNearDuplicate: Bool,
        sourceDuration: TimeInterval = 0,
        skip: Bool,
        extractedArtwork: Data? = nil
    ) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.originalTitle = originalTitle
        self.originalFilename = originalFilename
        self.detectedTrackName = detectedTrackName
        self.detectedVersionLabel = detectedVersionLabel
        self.editableVersionLabel = editableVersionLabel
        self.hasDetectedVersion = hasDetectedVersion
        self.matchKind = matchKind
        self.mixVsVersionAmbiguous = mixVsVersionAmbiguous
        self.sourceContentHash = sourceContentHash
        self.isExactDuplicate = isExactDuplicate
        self.isNearDuplicate = isNearDuplicate
        self.sourceDuration = sourceDuration
        self.skip = skip
        self.extractedArtwork = extractedArtwork
    }
}

public struct ParsedImportTitle {
    public let originalTitle: String
    public let detectedTrackName: String
    public let detectedVersionLabel: String
    public let hasDetectedVersion: Bool
    /// True when the suffix could plausibly mean either mix or version (e.g. `_final2`).
    public let mixVsVersionAmbiguous: Bool
    /// Raw date stem if the filename is a YYMMDD_N pattern, else nil.
    public let dateStem: String?

    public init(
        originalTitle: String,
        detectedTrackName: String,
        detectedVersionLabel: String,
        hasDetectedVersion: Bool,
        mixVsVersionAmbiguous: Bool,
        dateStem: String?
    ) {
        self.originalTitle = originalTitle
        self.detectedTrackName = detectedTrackName
        self.detectedVersionLabel = detectedVersionLabel
        self.hasDetectedVersion = hasDetectedVersion
        self.mixVsVersionAmbiguous = mixVsVersionAmbiguous
        self.dateStem = dateStem
    }
}

// MARK: - ImportPlanning Namespace

public enum ImportPlanning {

    /// Suggest an optional recording day without changing the existing
    /// `YYMMDD_N` track-matching rules.
    public nonisolated static func inferRecordingDate(from title: String) -> String? {
        RecordingDate.infer(from: title)
    }

    // MARK: - Title Parsing

    public nonisolated static func parseImportTitle(from filename: String) -> ParsedImportTitle {
        let url = URL(fileURLWithPath: filename)
        let stemRaw = url.deletingPathExtension().lastPathComponent
        let originalTitle = cleanupTitle(stemRaw)

        let dateStem = parseDateStem(stemRaw)

        // Pass 1: explicit mix-number suffix (e.g. "Song 1.01"). vN / version N markers are
        // intentionally NOT detected — those are part of the track title (a separate track),
        // not a mix label on a child of an existing track.
        let nsName = originalTitle as NSString
        let fullRange = NSRange(location: 0, length: nsName.length)
        if let match = mixNumberPattern.firstMatch(in: originalTitle, range: fullRange),
           match.numberOfRanges >= 3 {
            let nameRange = match.range(at: 1)
            let numRange = match.range(at: 2)
            if nameRange.location != NSNotFound, numRange.location != NSNotFound {
                let trackName = cleanupTitle(nsName.substring(with: nameRange))
                let mixNum = nsName.substring(with: numRange)
                return ParsedImportTitle(
                    originalTitle: originalTitle,
                    detectedTrackName: trackName,
                    detectedVersionLabel: mixNum,
                    hasDetectedVersion: true,
                    mixVsVersionAmbiguous: false,
                    dateStem: dateStem
                )
            }
        }

        // Pass 2: semantic suffix WITH trailing number (final2, alt3) — ambiguous between
        // a mix label and a brand-new track suffix. UI exposes a "(track or mix?)" tag.
        if let (trackName, label) = detectSemanticLabelWithNumber(in: originalTitle) {
            return ParsedImportTitle(
                originalTitle: originalTitle,
                detectedTrackName: trackName,
                detectedVersionLabel: label,
                hasDetectedVersion: true,
                mixVsVersionAmbiguous: true,
                dateStem: dateStem
            )
        }

        // Pass 3: bare semantic suffix (demo, rough mix, final) — clearly a mix label.
        if let (trackName, label) = detectSemanticLabel(in: originalTitle) {
            return ParsedImportTitle(
                originalTitle: originalTitle,
                detectedTrackName: trackName,
                detectedVersionLabel: label,
                hasDetectedVersion: true,
                mixVsVersionAmbiguous: false,
                dateStem: dateStem
            )
        }

        return ParsedImportTitle(
            originalTitle: originalTitle,
            detectedTrackName: originalTitle,
            detectedVersionLabel: "",
            hasDetectedVersion: false,
            mixVsVersionAmbiguous: false,
            dateStem: dateStem
        )
    }

    /// Match `YYMMDD_N` or `YYMMDD_N something` style filename stems.
    public nonisolated static func parseDateStem(_ raw: String) -> String? {
        let regex = try? NSRegularExpression(
            pattern: #"^(\d{6}_\d+)(?:[\s\-_].*)?$"#
        )
        let nsRaw = raw as NSString
        let range = NSRange(location: 0, length: nsRaw.length)
        guard let match = regex?.firstMatch(in: raw, range: range),
              match.numberOfRanges >= 2 else { return nil }
        let stemRange = match.range(at: 1)
        guard stemRange.location != NSNotFound else { return nil }
        return nsRaw.substring(with: stemRange)
    }

    /// Extract a mix-number string from filename if present (e.g. "3.01" → "3.01").
    /// The number token may be followed directly by letters (a stray format fragment,
    /// e.g. "1.01wav"); any following digit is still rejected so "1.011" does not
    /// yield a partial match.
    public nonisolated static func parseMixNumber(from filename: String) -> String? {
        let regex = try? NSRegularExpression(pattern: #"\b(\d+\.\d{1,2})(?!\d)"#)
        let ns = filename as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex?.firstMatch(in: filename, range: range),
              match.numberOfRanges >= 2,
              match.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Matcher

    public nonisolated static func matchTracks(
        parsedTitle: ParsedImportTitle,
        tracks: [Track]
    ) -> MatchKind {
        // Rule 1: working-title prefix match.
        let detected = normalizedForMatch(parsedTitle.detectedTrackName)
        if !detected.isEmpty {
            let titleMatches: [Track] = tracks.compactMap { track in
                let raw = track.workingTitle
                let normalized: String
                if let raw = raw, !raw.isEmpty {
                    normalized = normalizedForMatch(raw)
                } else {
                    normalized = normalizedForMatch(track.name)
                }
                guard !normalized.isEmpty else { return nil }
                return titlesMatch(detected, normalized) ? track : nil
            }
            if titleMatches.count == 1 {
                return .workingTitlePrefix(titleMatches[0].id)
            } else if titleMatches.count > 1 {
                return .ambiguous(titleMatches.map(\.id))
            }
        }

        // Rule 2: date-stem match. Compare the source file's stem against existing Track.name
        // and Version.originalFilename stems.
        if let stem = parsedTitle.dateStem {
            for track in tracks {
                let trackStemFromName = normalizedForMatch(parseDateStem(track.name) ?? "")
                if !trackStemFromName.isEmpty, trackStemFromName == stem {
                    return .dateStem(track.id)
                }
                for version in track.versions {
                    let verStem = parseDateStem(URL(fileURLWithPath: version.originalFilename).deletingPathExtension().lastPathComponent) ?? ""
                    if verStem == stem {
                        return .dateStem(track.id)
                    }
                }
            }
        }

        // Rule 3: no match → new track.
        return .none
    }

    // MARK: - Grouping

    /// Fuse imported items into groups. First, items whose matcher resolved to the same
    /// existing Track land in one group targeting that Track. Then, among the unmatched
    /// items, those sharing a `cleanedBaseName` (and whose name is at least 2 chars) fuse
    /// into a single new-track group — so dropping `Song A v1`, `Song A v2`, `Song A final`
    /// becomes one card with three version rows. Ambiguous matches stay as singleton
    /// `.unresolved` groups regardless of base name (we don't want to fuse them away
    /// before the user has resolved the disambiguation).
    public nonisolated static func groupItems(_ items: [ImportPlanItem]) -> [ImportPlanGroup] {
        var groups: [ImportPlanGroup] = []
        var indexByTargetID: [UUID: Int] = [:]
        var indexByBaseName: [String: Int] = [:]

        for item in items {
            if let targetID = item.matchKind.resolvedTrackID {
                if let existing = indexByTargetID[targetID] {
                    groups[existing].items.append(item)
                    if groups[existing].extractedArtwork == nil {
                        groups[existing].extractedArtwork = item.extractedArtwork
                    }
                } else {
                    indexByTargetID[targetID] = groups.count
                    groups.append(ImportPlanGroup(
                        target: .existingTrack(targetID),
                        editableTrackName: item.detectedTrackName,
                        extractedArtwork: item.extractedArtwork,
                        items: [item]
                    ))
                }
                continue
            }

            // Ambiguous matches gate the importer; keep them in their own group so the user
            // sees one row per file with the warning still attached.
            if case .ambiguous = item.matchKind {
                groups.append(ImportPlanGroup(
                    target: .unresolved,
                    editableTrackName: item.detectedTrackName,
                    extractedArtwork: item.extractedArtwork,
                    items: [item]
                ))
                continue
            }

            // Plain new-track item: bucket by cleanedBaseName so multiple files sharing a
            // base name fuse into one group. Skip fusion for single-character names —
            // they're almost always spurious (numeric stems, leftover punctuation).
            let key = cleanedBaseName(for: item)
            if !key.isEmpty, key.count >= 2, let existing = indexByBaseName[key] {
                groups[existing].items.append(item)
                if groups[existing].extractedArtwork == nil {
                    groups[existing].extractedArtwork = item.extractedArtwork
                }
            } else {
                if !key.isEmpty, key.count >= 2 {
                    indexByBaseName[key] = groups.count
                }
                groups.append(ImportPlanGroup(
                    target: .newTrack,
                    editableTrackName: item.detectedTrackName,
                    extractedArtwork: item.extractedArtwork,
                    items: [item]
                ))
            }
        }

        return groups
    }

    /// Normalized shared-name key used for batch grouping unmatched files. Exposed so the
    /// importer can introspect grouping decisions in tests and logs.
    public nonisolated static func cleanedBaseName(for item: ImportPlanItem) -> String {
        normalizedForMatch(item.detectedTrackName)
    }

    // MARK: - Hashing

    /// Streaming SHA-256 of the file at `url`. Does not load the whole file into memory.
    /// Security-scope is started when available (NSOpenPanel); drag-and-drop URLs may return
    /// false from `startAccessingSecurityScopedResource` but remain readable unsandboxed.
    public nonisolated static func fileContentHash(at url: URL) -> String? {
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }
        return try? FileIntegrity.sha256Hex(for: url)
    }

    /// Async duration peek used during planning. Returns 0 on failure — caller treats
    /// that as "duration unknown", which suppresses the near-duplicate flag.
    public nonisolated static func fileDuration(at url: URL) async -> TimeInterval {
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        do {
            let cm = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(cm)
            return seconds.isFinite && seconds > 0 ? seconds : 0
        } catch {
            return 0
        }
    }

    /// Synchronous duration peek kept for callers that are not yet on the async path
    /// (e.g. iOS import planning). Prefer `fileDuration(at:)` from async contexts.
    public nonisolated static func fileDurationSync(at url: URL) -> TimeInterval {
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let cm = asset.duration
        let seconds = CMTimeGetSeconds(cm)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    // MARK: - Internal Helpers

    public nonisolated static func cleanupTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    nonisolated static let semanticLabels: [String] = [
        "rough mix", "radio edit", "alternate", "final", "demo", "alt",
        "mix", "master", "edit", "instrumental", "radio", "vocal",
        "extended", "clean", "dirty"
    ]

    nonisolated static func detectSemanticLabel(in title: String) -> (String, String)? {
        let lower = title.lowercased()
        for label in semanticLabels {
            let pattern = #"^(.*?)[\s\-_]+"# + NSRegularExpression.escapedPattern(for: label) + #"\s*$"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let nsLower = lower as NSString
            let range = NSRange(location: 0, length: nsLower.length)
            guard let match = regex.firstMatch(in: lower, range: range) else { continue }
            let nameRange = match.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let rawName = (title as NSString).substring(with: nameRange)
            let trackName = cleanupTitle(rawName)
            guard !trackName.isEmpty else { continue }
            return (trackName, label)
        }
        return nil
    }

    /// Detect `<name><sep><label><N>` (ambiguous: mix-N or version-N).
    nonisolated static func detectSemanticLabelWithNumber(in title: String) -> (String, String)? {
        let lower = title.lowercased()
        for label in semanticLabels {
            let pattern = #"^(.*?)[\s\-_]+"# + NSRegularExpression.escapedPattern(for: label) + #"\s*(\d+)\s*$"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let nsLower = lower as NSString
            let range = NSRange(location: 0, length: nsLower.length)
            guard let match = regex.firstMatch(in: lower, range: range), match.numberOfRanges >= 3 else { continue }
            let nameRange = match.range(at: 1)
            let numRange = match.range(at: 2)
            guard nameRange.location != NSNotFound, numRange.location != NSNotFound else { continue }
            let rawName = (title as NSString).substring(with: nameRange)
            let trackName = cleanupTitle(rawName)
            guard !trackName.isEmpty else { continue }
            let num = nsLower.substring(with: numRange)
            return (trackName, "\(label)\(num)")
        }
        return nil
    }

    /// Mix-number suffix on a filename (e.g. "Song 1.01" → trackName="Song", mix="1.01").
    /// Pure-numeric vN / `#N` patterns are intentionally NOT included — those denote a
    /// separate track, not a mix on an existing one.
    ///
    /// Trailing letters glued directly onto the number are tolerated and treated as a
    /// stray format fragment (e.g. "die motions 1.01wav.mp3" → mix="1.01"). A separator
    /// before trailing words is deliberately NOT tolerated, so semantic suffixes such as
    /// "Song 1.01 demo" still fall through to the semantic-label passes.
    nonisolated static let mixNumberPattern: NSRegularExpression =
        try! NSRegularExpression(pattern: #"^(.+?)(?:[\s_-]+|\s*\()(\d+\.\d+)\)?[A-Za-z]*\s*$"#)

    /// Normalize for matcher comparisons: lowercased, separators collapsed, whitespace trimmed.
    nonisolated static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + " ") || rhs.hasPrefix(lhs + " ")
    }

    nonisolated static func normalizedForMatch(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let separators = folded.replacingOccurrences(of: #"[_\-.]+"#, with: " ", options: .regularExpression)
        let stripped = separators.replacingOccurrences(of: #"[^a-z0-9 ]+"#, with: " ", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
