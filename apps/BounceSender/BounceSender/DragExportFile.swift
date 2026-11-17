import Foundation
import AppKit

enum DragExportFile {
    private static let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("BounceDragExport", isDirectory: true)
    private static let staleAfter: TimeInterval = 24 * 60 * 60

    static func isOwnExport(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path + "/")
    }

    static func isInternalDrag(_ pasteboard: NSPasteboard) -> Bool {
        let internalTypes = [
            "com.merlinkraemer.bounce.library-version-item",
            "com.merlinkraemer.bounce.playlist-entry-item",
            "com.merlinkraemer.bounce.playlist-row",
            "com.merlinkraemer.bounce.folder-row"
        ].map { NSPasteboard.PasteboardType($0) }
        if pasteboard.availableType(from: internalTypes) != nil { return true }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains(where: isOwnExport)
    }

    static func excludingOwnExports(_ urls: [URL]) -> [URL] {
        urls.filter { !isOwnExport($0) }
    }

    static func add(to item: NSPasteboardItem, filePath: String?, trackName: String, versionLabel: String?) {
        guard let filePath, !filePath.isEmpty,
              let url = namedCopy(ofFileAt: URL(fileURLWithPath: filePath), trackName: trackName, versionLabel: versionLabel)
        else { return }
        item.setString(url.absoluteString, forType: .fileURL)
    }

    private static func namedCopy(ofFileAt source: URL, trackName: String, versionLabel: String?) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        removeStaleExports()

        let title = [trackName, versionLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
        let fileName = sanitized(title.isEmpty ? "Track" : title) + "." + source.pathExtension
        let directory = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(fileName)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private static func sanitized(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = name.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.drop(while: { $0 == "." }).prefix(120))
    }

    private static func removeStaleExports() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-staleAfter)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
