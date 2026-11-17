import SwiftUI
import SwiftData
import BounceKit

/// "Developer" section for Settings. Rendered only in the dev lane.
struct DevSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var confirmPairingReset = false
    @State private var confirmDataReset = false
    @State private var notice: String?

    var body: some View {
        if DevFeatures.isEnabled {
            Section {
                Button("Show Setup Again") { showSetupAgain() }
                Button("Reset Pairing\u{2026}") { confirmPairingReset = true }
                Button("Reset All Dev Data\u{2026}", role: .destructive) { confirmDataReset = true }
                if let notice {
                    Text(notice).foregroundStyle(.secondary)
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Development build only. Affects the dev lane, never production.")
            }
            .confirmationDialog("Reset pairing for the dev lane?", isPresented: $confirmPairingReset, titleVisibility: .visible) {
                Button("Reset Pairing", role: .destructive) { resetPairing() }
            } message: {
                Text("Removes the dev pairing key and paired Mac. Restart the app afterwards.")
            }
            .confirmationDialog("Reset all dev data?", isPresented: $confirmDataReset, titleVisibility: .visible) {
                Button("Reset All Dev Data", role: .destructive) { resetAll() }
            } message: {
                Text("Clears pairing, onboarding flags, preferences and the dev library.")
            }
        }
    }

    private func showSetupAgain() {
        guard BounceConstants.isDevelopmentBuild else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ReceiverAppStorageKeys.hasSeenReceiverOnboarding)
        defaults.removeObject(forKey: ReceiverAppStorageKeys.hasEverPairedReceiverDevice)
        dismiss()
    }

    private func resetPairing() {
        guard BounceConstants.isDevelopmentBuild else { return }
        DevFeatures.resetPairing()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ReceiverAppStorageKeys.hasEverPairedReceiverDevice)
        notice = "Pairing reset. Restart the app to finish."
    }

    private func resetAll() {
        guard BounceConstants.isDevelopmentBuild else { return }
        DevFeatures.resetPairing()
        do {
            modelContext.container.deleteAllData()
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let library = docs.appendingPathComponent("Bounce", isDirectory: true)
            if FileManager.default.fileExists(atPath: library.path) {
                try FileManager.default.removeItem(at: library)
            }
        } catch {
            notice = "Reset failed: \(error.localizedDescription)"
            return
        }
        DevFeatures.resetUserDefaults()
        notice = "Dev data reset. Restart the app to finish."
    }
}
