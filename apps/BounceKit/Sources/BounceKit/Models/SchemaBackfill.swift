import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// One-shot backfills for schema additions made after a Track row already exists.
/// Idempotent: each backfill keys off a sentinel value on the row, so re-running is safe.
public enum SchemaBackfill {

    /// Populates `Track.lastTouchedAt` for rows that still hold the `.distantPast` sentinel
    /// written by the lightweight migration. Sets it to max(updatedAt, latest version.addedAt).
    @MainActor
    public static func backfillLastTouchedAt(in context: ModelContext) {
        let sentinel = Date.distantPast
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.lastTouchedAt == sentinel }
        )
        guard let tracks = try? context.fetch(descriptor), !tracks.isEmpty else { return }
        for track in tracks {
            let latestVersionDate = track.versions.map(\.addedAt).max() ?? .distantPast
            track.lastTouchedAt = max(track.updatedAt, latestVersionDate)
        }
        try? context.save()
    }

    /// Blobs above this size are legacy (pre-dating the JPEG-1024 re-encode fix, e.g.
    /// uncompressed TIFF playlist covers) and get re-encoded. Re-encoded output lands far
    /// below this, so the threshold doubles as the idempotency sentinel — no separate
    /// "already migrated" flag needed.
    public static let oversizedImageThreshold = 500_000

    /// Re-encodes oversized legacy `Track.artwork` / `Playlist.coverImageData` blobs (inline
    /// multi-MB TIFFs from before `.externalStorage` + the JPEG re-encode fix existed) down to
    /// a bounded JPEG. Runs entirely against its own `ModelContext` on a background executor —
    /// callers should invoke this from a detached/utility `Task`, never inline on the launch
    /// critical path, since decoding + downsampling a legacy ~34 MB TIFF is real work.
    ///
    /// The re-encode is pure ImageIO (no AppKit/UIKit), so Mac and iOS reduce the same synced
    /// source bytes to matching output — that keeps the byte-derived `artworkRevision`
    /// fingerprint (`LibraryManifest.artworkRevision(for:)`) consistent on both sides.
    ///
    /// Deliberately does NOT touch `updatedAt` / `lastTouchedAt`: both apps run this backfill
    /// independently, and playlist-cover sync is last-write-wins on `updatedAt`
    /// (`mergePlaylistEntries`). Bumping it here would make a locally-backfilled cover look
    /// "newer" than the peer's and force a one-sided overwrite each time either side
    /// re-encodes — with both sides converging to the same bytes on their own, there's nothing
    /// to reconcile, so timestamps are left as-is.
    public static func backfillOversizedArtwork(container: ModelContainer) async {
        let context = ModelContext(container)
        var didChange = false

        if let tracks = try? context.fetch(FetchDescriptor<Track>()) {
            for track in tracks {
                if let data = track.artwork, data.count > oversizedImageThreshold,
                   let reencoded = reencodedJPEG(from: data), reencoded.count < data.count {
                    // setArtwork keeps the stored artworkRevision in lockstep with
                    // the new bytes; both apps re-encode to identical output (pure
                    // ImageIO), so revisions converge and artwork doesn't re-transfer.
                    track.setArtwork(reencoded)
                    didChange = true
                } else if track.artworkRevision == nil, track.artwork != nil {
                    // Rows from before the stored revision existed: derive it here,
                    // off the launch critical path, so manifest builds stay blob-free.
                    _ = track.resolvedArtworkRevision()
                    didChange = true
                }
            }
        }

        if let playlists = try? context.fetch(FetchDescriptor<Playlist>()) {
            for playlist in playlists {
                if let data = playlist.coverImageData, data.count > oversizedImageThreshold,
                   let reencoded = reencodedJPEG(from: data), reencoded.count < data.count {
                    // setCoverImage keeps the stored coverRevision in lockstep with the
                    // new bytes; both apps re-encode to identical output (pure ImageIO),
                    // so revisions converge and covers don't re-transfer.
                    playlist.setCoverImage(reencoded)
                    didChange = true
                } else if playlist.coverRevision == nil, playlist.coverImageData != nil {
                    _ = playlist.resolvedCoverRevision()
                    didChange = true
                }
            }
        }

        guard didChange else { return }
        try? context.save()
    }

    /// Downsample + JPEG encode via ImageIO alone (no AppKit/UIKit) so it runs identically on
    /// Mac and iOS. Mirrors BounceSender's `ArtworkThumbnailCache.encodedCoverData` parameters
    /// (1024px long edge, quality 0.85) so re-encoded output matches the app's normal
    /// day-to-day cover-save path.
    private static func reencodedJPEG(from data: Data, maxPixelSize: Int = 1024, quality: CGFloat = 0.85) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }

        let outData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let destinationProperties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, destinationProperties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outData as Data
    }
}
