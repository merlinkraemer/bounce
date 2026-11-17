import Foundation
import AVFoundation
import BounceKit

/// Snapshot of metadata extracted from an audio file's embedded tags.
/// All fields are optional — a file with no tags returns an empty struct.
struct TrackMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var bpm: Double?
    var artwork: Data?

    static let empty = TrackMetadata()
}

/// Reads ID3v2 / iTunes / common metadata tags and embedded cover art from
/// an audio file using AVAsset. Failure is non-throwing — it logs a warning
/// and returns whatever was successfully read (possibly `.empty`).
enum MetadataExtractor {
    static func extract(from url: URL) async -> TrackMetadata {
        let asset = AVURLAsset(url: url)
        var metadata = TrackMetadata()

        do {
            let items = try await asset.load(.metadata)
            for item in items {
                await apply(item: item, into: &metadata)
            }
        } catch {
            SyncLog.importer.warning("metadata load failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return metadata
        }

        return metadata
    }

    private static func apply(item: AVMetadataItem, into metadata: inout TrackMetadata) async {
        guard let key = item.commonKey?.rawValue ?? item.key as? String else { return }

        switch key {
        case AVMetadataKey.commonKeyTitle.rawValue:
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                metadata.title = value
            }
        case AVMetadataKey.commonKeyArtist.rawValue:
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                metadata.artist = value
            }
        case AVMetadataKey.commonKeyAlbumName.rawValue:
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                metadata.album = value
            }
        case AVMetadataKey.commonKeyArtwork.rawValue:
            if let data = try? await item.load(.dataValue), !data.isEmpty {
                metadata.artwork = data
            }
        case "TBPM", "BPM": // ID3v2 BPM frame, raw key
            if let value = try? await item.load(.stringValue), let bpm = Double(value) {
                metadata.bpm = bpm
            } else if let value = try? await item.load(.numberValue) {
                metadata.bpm = value.doubleValue
            }
        default:
            break
        }
    }
}
