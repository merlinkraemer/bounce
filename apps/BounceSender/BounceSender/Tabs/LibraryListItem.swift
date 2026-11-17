import Foundation
import AppKit
import ImageIO
import BounceKit

/// One row in the flattened library list — every Version of every Track
/// becomes its own snapshot so the table can show grouped versions
/// without a parent/child outline.
///
/// Artwork bytes stay out of the snapshot: list rebuilds / equality use the
/// stored `artworkRevision` scalar; cells load bytes lazily for visible rows.
enum LibraryRowKind: Equatable {
    case parent
    case mix
    case flat
}

/// Single source of truth for the track row's horizontal geometry. The row
/// (`LibraryRowView`) and the column header (`LibraryListView.header`) both
/// build their HStack from these, so header labels cannot drift off the cells.
enum LibraryRowMetrics {
    static let leadingInset: CGFloat = 12
    static let trailingInset: CGFloat = 16
    static let spacing: CGFloat = 12
    static let expansionWidth: CGFloat = 24
    static let artworkSide: CGFloat = 40
    static let contentGapMin: CGFloat = 8
    static let dateWidth: CGFloat = 64
    static let durationWidth: CGFloat = 64
    static let menuGap: CGFloat = 8
    static let menuWidth: CGFloat = 20
}

struct LibraryColumnVisibility: Equatable {
    let showsAdded: Bool
    let showsDuration: Bool
    let foldsMixIntoSubtitle: Bool

    init(width: CGFloat) {
        showsAdded = LibraryColumnVisibilityRules.showsAdded(atWidth: width)
        showsDuration = LibraryColumnVisibilityRules.showsDuration(atWidth: width)
        foldsMixIntoSubtitle = LibraryColumnVisibilityRules.foldsMixIntoSubtitle(atWidth: width)
    }
}

struct LibraryTrackRowSnapshot: Identifiable, Equatable {
    let id: String
    let trackID: UUID
    let trackName: String
    let artworkRevision: Int64?
    let versionID: UUID
    let versionLabel: String
    let versionCountInGroup: Int
    let isLatestVersion: Bool
    let hasOlderVersions: Bool
    let isExpanded: Bool
    let addedAt: Date
    let duration: TimeInterval
    let filePath: String
    let processingState: ProcessingState
    let isReleased: Bool
    let rowKind: LibraryRowKind
    let noteCount: Int
    let isViewingOlderVersion: Bool
    /// When false, omit the expand-chevron gutter (Sets list has no mix expansion).
    let showsExpansionControl: Bool
}

/// Decodes and downsamples album artwork once, caching the small thumbnail so
/// table cells don't decode full-resolution image Data on every configure or
/// scroll. Keyed by id + display size + revision (or byte count fallback).
///
/// Also owns cover **encode** for persistence: always JPEG at a bounded long
/// edge — never uncompressed TIFF into the store/manifest.
enum ArtworkThumbnailCache {
    /// Long-edge cap for newly saved track/playlist covers.
    static let storedMaxPixelSize = 1024
    static let jpegQuality: CGFloat = 0.85

    private static var cache: [String: NSImage] = [:]

    @MainActor
    static func thumbnail(_ data: Data, id: UUID, side: CGFloat, revision: Int64? = nil) -> NSImage? {
        let maxPixel = Int((side * 2).rounded())
        let fingerprint = revision.map { "r\($0)" } ?? "c\(data.count)"
        let key = "\(id.uuidString)-\(maxPixel)-\(fingerprint)"
        if let cached = cache[key] { return cached }
        guard let image = downsample(data, maxPixel: maxPixel) else { return nil }
        cache[key] = image
        return image
    }

    /// Downscale + JPEG for store/sync. Prefer this over `tiffRepresentation`.
    static func encodedCoverData(from image: NSImage, maxPixelSize: Int = storedMaxPixelSize) -> Data? {
        // TIFF is only an intermediate decode buffer — never persisted.
        guard let tiff = image.tiffRepresentation else { return nil }
        return encodedCoverData(from: tiff, maxPixelSize: maxPixelSize)
    }

    /// Downscale + JPEG from already-encoded image bytes (PNG/JPEG/HEIC/TIFF).
    static func encodedCoverData(from data: Data, maxPixelSize: Int = storedMaxPixelSize) -> Data? {
        guard let cgImage = downsampledCGImage(from: data, maxPixel: maxPixelSize) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let cgImage = downsampledCGImage(from: data, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func downsampledCGImage(from data: Data, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Either a track row or an inter-track separator. The table view treats
/// separators as non-selectable, fixed-height divider rows.
enum LibraryListItem: Identifiable, Equatable {
    case row(LibraryTrackRowSnapshot)
    case separator(String)

    var id: String {
        switch self {
        case let .row(snapshot):
            return snapshot.id
        case let .separator(id):
            return id
        }
    }

    var rowSnapshot: LibraryTrackRowSnapshot? {
        if case let .row(snapshot) = self {
            return snapshot
        }
        return nil
    }
}
