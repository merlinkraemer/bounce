import Foundation

/// Tracks where a Track originated from — used for bidirectional sync authority.
/// Mac-originated tracks are authoritative on Mac; phone-originated on phone.
public enum TrackOrigin: String, Codable, Sendable {
    case mac
    case phone

    /// Default origin for tracks created on the current device before origin tracking existed.
    public static let unknown = TrackOrigin.mac
}
