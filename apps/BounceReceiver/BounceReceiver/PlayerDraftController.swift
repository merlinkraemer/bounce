import Foundation
import Observation

@Observable
@MainActor
final class PlayerDraftController {
    var draftText: String = ""
    var draftTimestamp: TimeInterval?
    var isTimestampLocked: Bool = false
    var showDiscardAlert: Bool = false
    var pendingDiscardAction: (() -> Void)?

    var hasDraft: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func attempt(action: @escaping () -> Void) {
        guard hasDraft else {
            action()
            return
        }
        pendingDiscardAction = action
        showDiscardAlert = true
    }

    func confirmDiscard() {
        draftText = ""
        draftTimestamp = nil
        isTimestampLocked = false
        showDiscardAlert = false
        pendingDiscardAction?()
        pendingDiscardAction = nil
    }

    func cancelDiscard() {
        showDiscardAlert = false
        pendingDiscardAction = nil
    }

    func clearDraft() {
        draftText = ""
        draftTimestamp = nil
        isTimestampLocked = false
    }
}
