import Foundation

/// Every persisted `UserDefaults` key used by the apps.
///
/// These strings are part of the on-disk contract: existing installs carry
/// their values forward under exactly these keys, so they must never change.
/// `PreferenceKeyTests` pins each raw string and verifies round-tripping.
public enum BouncePreferenceKey {
    // MARK: Library
    /// Raw value of `AllTracksSortMode`.
    public static let allTracksSortMode = "allTracksSortMode"
    /// Whether the details/inspector pane is shown (live window state).
    public static let detailsVisible = "bounce.mac.detailsVisible"
    /// Whether the details pane starts open at launch. The live
    /// `detailsVisible` value is seeded from this key on launch.
    public static let detailsVisibleByDefault = "bounce.mac.detailsVisibleByDefault"
    /// UUID string of the mix open in the inspector at launch (session state).
    public static let inspectedVersionID = "bounce.mac.inspectedVersionID"

    // MARK: Navigation
    /// Whether the Releases destination is listed in the library sidebar.
    public static let showReleasesTab = "bounce.mac.showReleasesTab"
    /// Whether the Sets destination is listed in the library sidebar.
    public static let showSetsTab = "bounce.mac.showSetsTab"

    // MARK: General
    /// Whether the menu bar extra is inserted.
    public static let showMenuBarItem = "bounce.mac.showMenuBarItem"

    // MARK: Playback
    /// UUID string of the last played version (session state).
    public static let lastPlayedVersionID = "lastPlayedVersionID"

    // MARK: Sync
    public static let senderDeviceID = "com.bounce.sync.senderDeviceID"
    public static let receiverDeviceID = "com.bounce.sync.receiverDeviceID"
    /// Pre-rename sender device ID, read once for migration.
    public static let legacySenderDeviceID = "com.bounce.senderID"
    public static let autoConnectPaused = "com.bounce.autoConnectPaused"
    /// iPhone-side display name sent to the Mac. Empty or unset falls back to
    /// `UIDevice.current.name`, which iOS 16+ reduces to the model name.
    public static let receiverDeviceName = "com.bounce.sync.receiverDeviceName"
}

/// Fallback values applied when a preference key has never been written.
public enum BouncePreferenceDefault {
    public static let allTracksSortMode = AllTracksSortMode.dateAdded.rawValue
    public static let detailsVisible = true
    public static let detailsVisibleByDefault = true
    public static let showReleasesTab = true
    /// Recordings are opt-in; an existing stored value always wins.
    public static let showSetsTab = false
    public static let showMenuBarItem = true
}
