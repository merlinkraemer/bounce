import Foundation

/// Tracks the import processing lifecycle of a track.
/// Used by the optimistic-import UI: pending tracks appear as ghost rows
/// with a spinner; complete tracks render normally; failed tracks show
/// an error state with a retry affordance.
public enum ProcessingState: String, Codable, Sendable {
    case pending
    case complete
    case failed
}
