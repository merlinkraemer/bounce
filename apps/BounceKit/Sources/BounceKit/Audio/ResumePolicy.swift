import Foundation

/// Decides whether a track restarts from a saved position. Only sets
/// (long-form recordings) resume; every other track starts at 0.
public enum ResumePolicy {
    /// Minimum saved position worth resuming, and minimum distance from the end.
    public static let threshold: TimeInterval = 3

    public static func shouldTrack(isSet: Bool) -> Bool { isSet }

    /// Position to seek to on load, or nil to start at 0.
    public static func resumePosition(
        isSet: Bool,
        saved: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard isSet, saved >= threshold, duration > saved + threshold else { return nil }
        return saved
    }

    /// True when a saved position is at/near the end and should be cleared.
    public static func isFinished(saved: TimeInterval, duration: TimeInterval) -> Bool {
        saved > 0 && duration > 0 && saved >= duration - threshold
    }
}
