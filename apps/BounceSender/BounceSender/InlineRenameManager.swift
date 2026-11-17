import SwiftUI

@Observable
final class InlineRenameManager {
    struct Target: Equatable {
        enum Kind: Equatable { case track, version, playlist, playlistFolder }
        let kind: Kind
        let id: UUID
    }

    private(set) var activeTarget: Target?

    var editText: String = ""

    var onCommit: ((Target, String) -> Void)?
    var onDidBegin: ((Target) -> Void)?
    var onDidEnd: (() -> Void)?

    func begin(target: Target, initialText: String) {
        if activeTarget != nil { commit() }

        activeTarget = target
        editText = initialText
        onDidBegin?(target)
    }

    var editTextBinding: Binding<String> {
        Binding<String>(
            get: { self.editText },
            set: { self.editText = $0 }
        )
    }

    func commit() {
        guard let target = activeTarget else { return }
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onCommit?(target, trimmed)
        }
        end()
    }

    func cancel() {
        end()
    }

    private func end() {
        activeTarget = nil
        editText = ""
        onDidEnd?()
    }
}
