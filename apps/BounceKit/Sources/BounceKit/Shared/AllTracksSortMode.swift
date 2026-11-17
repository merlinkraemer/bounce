import Foundation

/// Catalogue sort modes, shared between the toolbar menu, the `@AppStorage`
/// raw value and the list ordering policy.
public enum AllTracksSortMode: String, CaseIterable, Identifiable {
    case dateAdded
    case name

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dateAdded: return "Date Added"
        case .name: return "Name"
        }
    }

    /// Display-order predicate for the catalogue. `dateAdded` sorts newest
    /// first; `name` sorts case-insensitively. Callers pass the date to sort
    /// on (`latestVersionDate ?? createdAt`) and the track name.
    public func precedes(
        lhsDate: Date,
        lhsName: String,
        rhsDate: Date,
        rhsName: String
    ) -> Bool {
        switch self {
        case .dateAdded:
            return lhsDate > rhsDate
        case .name:
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
    }
}
