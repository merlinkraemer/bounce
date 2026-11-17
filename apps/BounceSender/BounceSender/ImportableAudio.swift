import Foundation
import UniformTypeIdentifiers

/// The file types the library import pipeline accepts, shared by every import
/// surface (open panel, window drop, menu bar drop).
enum ImportableAudio {
    static let types: [UTType] = [
        .wav, .aiff, .mp3, .mpeg4Audio,
        UTType("public.flac") ?? .audio,
        UTType("public.aac-audio") ?? .audio
    ]

    static func isAudioFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }

        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return types.contains { contentType.conforms(to: $0) } || contentType.conforms(to: .audio)
        }

        guard let extensionType = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { extensionType.conforms(to: $0) } || extensionType.conforms(to: .audio)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// Audio files among `urls`; folders contribute their audio files recursively.
    static func expandedAudioURLs(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            if isDirectory(url) {
                let files = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let file = files?.nextObject() as? URL {
                    if isAudioFile(file) { result.append(file) }
                }
            } else if isAudioFile(url) {
                result.append(url)
            }
        }
        return result
    }
}
