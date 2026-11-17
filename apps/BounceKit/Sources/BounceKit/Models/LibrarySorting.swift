import Foundation

/// A group of Tracks that share a working title — the spec's "song" grouping.
/// Tracks without a working title each form their own singleton group keyed by their UUID.
public struct SiblingGroup: Identifiable, Hashable {
    public let id: String
    public let displayTitle: String
    public let tracks: [Track]

    public var maxLastTouchedAt: Date {
        tracks.map(\.lastTouchedAt).max() ?? .distantPast
    }

    /// Creation-date-based bucketing key used for month sectioning and sort order.
    /// Prefers each track's latest version `addedAt` (set by the importer to the
    /// source file's creationDate) and falls back to the track's own `createdAt`.
    /// We deliberately do NOT use `lastTouchedAt` here — that drifts whenever a
    /// note is edited or a version is added, which would shuffle sections around.
    public var bucketDate: Date {
        tracks.map { $0.latestVersionDate ?? $0.createdAt }.max() ?? .distantPast
    }

    public static func == (lhs: SiblingGroup, rhs: SiblingGroup) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// A bucket of sibling groups that share a calendar month.
public struct MonthSection: Identifiable {
    public let id: String
    public let label: String
    public let groups: [SiblingGroup]
}

public enum LibrarySorting {

    /// Normalize a working title for sibling-group matching: trimmed + lowercased.
    /// Empty after trimming = no working title.
    public static func normalizedWorkingTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Group tracks by normalized workingTitle. Tracks without a working title each
    /// become a singleton group. Within a group, sort by versionNumber asc (nil last).
    public static func groupBySiblings(_ tracks: [Track]) -> [SiblingGroup] {
        var grouped: [String: [Track]] = [:]
        var singletons: [SiblingGroup] = []

        for track in tracks {
            if let key = normalizedWorkingTitle(track.workingTitle) {
                grouped[key, default: []].append(track)
            } else {
                let id = "track:\(track.id.uuidString)"
                singletons.append(SiblingGroup(id: id, displayTitle: track.name, tracks: [track]))
            }
        }

        let multi = grouped.map { (key, tracks) -> SiblingGroup in
            let sorted = tracks.sorted { lhs, rhs in
                switch (lhs.versionNumber, rhs.versionNumber) {
                case let (l?, r?): return l < r
                case (nil, _?):    return false
                case (_?, nil):    return true
                default:           return lhs.lastTouchedAt < rhs.lastTouchedAt
                }
            }
            let displayTitle = sorted.first.flatMap { $0.workingTitle } ?? key
            return SiblingGroup(id: "title:\(key)", displayTitle: displayTitle, tracks: sorted)
        }

        return multi + singletons
    }

    /// The All Tracks list order: the latest sibling of each song group, in the
    /// month sections' display order.
    public static func allTracksOrder(_ tracks: [Track]) -> [Track] {
        let sorted = tracks.sorted {
            ($0.latestVersionDate ?? $0.createdAt) > ($1.latestVersionDate ?? $1.createdAt)
        }
        return sectionByMonth(groupBySiblings(sorted)).flatMap { $0.groups.compactMap { $0.tracks.last } }
    }

    /// The playback context for starting `track` from a list in `order`. An
    /// older sibling takes its song group's place; a track outside the list
    /// goes first.
    public static func playbackContext(for track: Track, in order: [Track]) -> [Track] {
        let key = normalizedWorkingTitle(track.workingTitle)
        return PlayQueueOps.context(for: track, id: \.id, in: order) { candidate in
            key != nil && normalizedWorkingTitle(candidate.workingTitle) == key
        }
    }

    /// Bucket sibling groups by month/year of their `bucketDate` (file creation date).
    /// Sections are ordered newest-first; groups within a section are ordered by
    /// `bucketDate` desc.
    public static func sectionByMonth(
        _ groups: [SiblingGroup],
        calendar: Calendar = .current
    ) -> [MonthSection] {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"

        var buckets: [DateComponents: [SiblingGroup]] = [:]
        for group in groups {
            let comps = calendar.dateComponents([.year, .month], from: group.bucketDate)
            buckets[comps, default: []].append(group)
        }

        return buckets
            .map { (comps, groups) -> MonthSection in
                let date = calendar.date(from: comps) ?? .distantPast
                let label = formatter.string(from: date)
                let sorted = groups.sorted { $0.bucketDate > $1.bucketDate }
                let id = "\(comps.year ?? 0)-\(comps.month ?? 0)"
                return MonthSection(id: id, label: label, groups: sorted)
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.groups.first?.bucketDate ?? .distantPast
                let rhsDate = rhs.groups.first?.bucketDate ?? .distantPast
                return lhsDate > rhsDate
            }
    }
}
