import SwiftUI
import UIKit
import BounceKit

/// Identifiable wrapper so list parents can present `ShareSheet` via `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

enum TrackShareURL {
    /// Resolves a shareable audio file URL. Prefers an explicit version when given,
    /// otherwise the track's latest mix.
    static func resolve(for track: Track, versionID: UUID? = nil) -> URL? {
        let version: Version?
        if let versionID {
            version = track.versions.first(where: { $0.id == versionID })
                ?? track.latestVersion
                ?? track.versions.first
        } else {
            version = track.latestVersion ?? track.versions.first
        }
        guard let path = version?.filePath else { return nil }
        return FileManager.default.fileExists(atPath: path)
            ? URL(fileURLWithPath: path)
            : nil
    }

    static func resolve(version: Version) -> URL? {
        let path = version.filePath
        return FileManager.default.fileExists(atPath: path)
            ? URL(fileURLWithPath: path)
            : nil
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onDismiss: (() -> Void)?

    init(items: [Any], onDismiss: (() -> Void)? = nil) {
        self.items = items
        self.onDismiss = onDismiss
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onDismiss?()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
