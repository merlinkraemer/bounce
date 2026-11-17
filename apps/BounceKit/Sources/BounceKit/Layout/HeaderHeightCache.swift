import CoreGraphics
import Foundation

/// Process-level cache of the last accepted header body heights, keyed by
/// surface identity (`"library"`, `"sets"`, `"playlist:<uuid>"`).
///
/// A surface's measured height lives in `LibraryContent`'s hoisted view state,
/// but `LibraryContent` itself is destroyed whenever the narrow-layout or
/// Releases branch replaces it, so this cache outlives the view and seeds the
/// next mount.
///
/// Invalidation contract: `store` replaces the value for its key, so a stale
/// estimate is corrected by the next accepted measurement and never survives
/// as a wrong final height. Keys are namespaced per surface, so a playlist's
/// height can never be read back as the library's or another playlist's.
public final class HeaderHeightCache: @unchecked Sendable {
    /// The process-wide cache used by the catalogue.
    public static let shared = HeaderHeightCache()

    public static let libraryKey = "library"
    public static let setsKey = "sets"
    public static func playlistKey(_ id: UUID) -> String { "playlist:\(id)" }

    private let lock = NSLock()
    private var heights: [String: CGFloat] = [:]

    public init() {}

    /// The last stored height for `key`, or 0 when the surface has never been
    /// measured.
    public func height(for key: String) -> CGFloat {
        lock.withLock { heights[key] ?? 0 }
    }

    /// Stores a freshly measured height, invalidating any previous value for
    /// the same key. The updated value is returned by later `height(for:)`
    /// calls.
    public func store(_ height: CGFloat, for key: String) {
        lock.withLock { heights[key] = height }
    }
}
