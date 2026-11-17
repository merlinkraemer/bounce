import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct ExternalFileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let perform: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) && !DragExportFile.isInternalDrag(NSPasteboard(name: .drag))
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let collected = LockedURLs()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            perform(collected.urls)
        }
        return true
    }
}

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        stored.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

extension View {
    func externalFileDrop(isTargeted: Binding<Bool>, perform: @escaping ([URL]) -> Void) -> some View {
        onDrop(of: [.fileURL], delegate: ExternalFileDropDelegate(isTargeted: isTargeted, perform: perform))
    }
}
