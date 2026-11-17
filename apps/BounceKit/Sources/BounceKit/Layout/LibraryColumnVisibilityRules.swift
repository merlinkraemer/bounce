import CoreGraphics

/// Width breakpoints for the catalogue list columns.
///
/// Extracted from `LibraryColumnVisibility` in BounceSender so the thresholds
/// are unit-testable. The view type keeps its shape and calls these predicates.
public enum LibraryColumnVisibilityRules {
    /// The "Added" column appears at or above this width.
    public static let addedMinWidth: CGFloat = 560
    /// The "Duration" column appears at or above this width.
    public static let durationMinWidth: CGFloat = 480
    /// Below this width the mix/version label folds into the row subtitle.
    public static let mixFoldMaxWidth: CGFloat = 400

    public static func showsAdded(atWidth width: CGFloat) -> Bool {
        width >= addedMinWidth
    }

    public static func showsDuration(atWidth width: CGFloat) -> Bool {
        width >= durationMinWidth
    }

    public static func foldsMixIntoSubtitle(atWidth width: CGFloat) -> Bool {
        width < mixFoldMaxWidth
    }
}
