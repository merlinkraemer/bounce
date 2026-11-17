import Foundation

/// User-facing words for the long-recording feature. Naming is still open;
/// change them here and every surface follows.
public enum RecordingsCopy {
    /// Plural name of the tab / shelf.
    public static let plural = "Recordings"
    /// Lowercase forms for counts ("3 recordings").
    public static let pluralLowercase = "recordings"
    public static let singularLowercase = "recording"
    /// Label of the per-track / import checkbox.
    public static let longRecording = "Add to Recordings"
    public static let removeFrom = "Remove from Recordings"
    public static let emptyTitle = "No Recordings"
    public static let emptyDescription = "Add a track to Recordings to see it here."
    public static let editFooterMac = "Tracks in Recordings are listed in the Recordings tab and resume from their last position on iPhone."
    public static let editFooterIOS = "Tracks in Recordings are listed in the Recordings tab and resume from their last position."
    public static let settingsToggle = "Show Recordings"
    public static let importHint = "Long file. Turn on Recordings in Settings to keep long recordings like DJ sets or live takes separate."
    public static let importHintButton = "Turn On"
}
