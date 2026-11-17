import Foundation

/// One existing sibling Track for the selected working title — either to attach a
/// rename to, or to use as a baseline when the user picks "new version (vN+1)".
public struct WorkingTitleSibling: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let versionNumber: Int?
    public let trackName: String
    public let mixCount: Int

    public init(id: UUID, versionNumber: Int?, trackName: String, mixCount: Int) {
        self.id = id
        self.versionNumber = versionNumber
        self.trackName = trackName
        self.mixCount = mixCount
    }

    public var displayLabel: String {
        let versionTag = versionNumber.map { "v\($0)" } ?? "unnumbered"
        let mixWord = mixCount == 1 ? "mix" : "mixes"
        return "\(versionTag) · \(mixCount) \(mixWord)"
    }
}

public enum WorkingTitleSuggestions {

    /// Distinct, non-empty working titles in the library, sorted case-insensitively.
    public static func distinctTitles(from tracks: [Track]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for track in tracks {
            guard let raw = track.workingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let key = raw.lowercased()
            if seen.insert(key).inserted {
                ordered.append(raw)
            }
        }
        return ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Working titles whose normalized form contains the typed prefix.
    /// Empty prefix → return all.
    public static func filteredTitles(prefix raw: String, from tracks: [Track]) -> [String] {
        let prefix = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = distinctTitles(from: tracks)
        guard !prefix.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(prefix) }
    }

    /// Existing sibling Tracks for a given working title. Used to drive the
    /// sibling picker when a rename joins an existing group. `excluding` skips the
    /// Track being renamed so it doesn't appear as its own sibling.
    public static func siblings(
        of title: String,
        in tracks: [Track],
        excluding excludedID: UUID? = nil
    ) -> [WorkingTitleSibling] {
        let normalized = LibrarySorting.normalizedWorkingTitle(title)
        guard let normalized else { return [] }
        return tracks.compactMap { track -> WorkingTitleSibling? in
            if track.id == excludedID { return nil }
            guard LibrarySorting.normalizedWorkingTitle(track.workingTitle) == normalized else { return nil }
            return WorkingTitleSibling(
                id: track.id,
                versionNumber: track.versionNumber,
                trackName: track.name,
                mixCount: track.versions.count
            )
        }.sorted { lhs, rhs in
            switch (lhs.versionNumber, rhs.versionNumber) {
            case let (l?, r?): return l < r
            case (nil, _?):    return false
            case (_?, nil):    return true
            default:           return lhs.trackName < rhs.trackName
            }
        }
    }

    /// The next free version number for a working-title group (max + 1).
    public static func nextVersionNumber(for title: String, in tracks: [Track], excluding excludedID: UUID? = nil) -> Int {
        let used = siblings(of: title, in: tracks, excluding: excludedID).compactMap(\.versionNumber)
        return (used.max() ?? 0) + 1
    }
}
