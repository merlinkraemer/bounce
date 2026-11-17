import CryptoKit
import Foundation

public enum FileIntegrity {
    public static func sha256Hex(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func fileSize(for fileURL: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw SyncError.transferFailed("missing file size for \(fileURL.lastPathComponent)")
        }
        return number.int64Value
    }

    public static func preferredFilename(for versionID: UUID, fileFormat: String) -> String {
        let trimmedFormat = fileFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = trimmedFormat.isEmpty ? "m4a" : trimmedFormat.lowercased()
        return "\(versionID.uuidString).\(ext)"
    }
}
