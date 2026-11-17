import SwiftUI
import AppKit
import BounceKit

/// "Developer" section for Settings → General. Rendered only in the dev lane.
struct DevSettingsSection: View {
    @Environment(\.openWindow) private var openWindow
    @State private var confirmPairingReset = false
    @State private var confirmDataReset = false
    @State private var notice: String?
    @State private var showQuitPrompt = false

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
            .confirmationDialog("Reset pairing for the dev lane?", isPresented: $confirmPairingReset) {
                Button("Reset Pairing", role: .destructive) { resetPairing() }
            } message: {
                Text("Removes the dev pairing key and paired iPhones. Restart Bounce afterwards.")
            }
            .confirmationDialog("Reset all dev data?", isPresented: $confirmDataReset) {
                Button("Reset All Dev Data", role: .destructive) { resetAll() }
            } message: {
                Text("Clears pairing, setup flags and preferences, and moves the dev library to a backup folder.")
            }
            .alert("Dev data reset", isPresented: $showQuitPrompt) {
                Button("Quit Now") { NSApp.terminate(nil) }
                Button("Later", role: .cancel) {}
            } message: {
                Text("Quit Bounce to finish. The next launch starts with a fresh library.")
            }
        }
    }

    private func showSetupAgain() {
        guard BounceConstants.isDevelopmentBuild else { return }
        UserDefaults.standard.removeObject(forKey: SetupPrefs.dismissedKey)
        SetupPrefs.requestSetup()
        openWindow(id: LibraryWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resetPairing() {
        guard BounceConstants.isDevelopmentBuild else { return }
        DevFeatures.resetPairing()
        UserDefaults.standard.removeObject(forKey: SetupPrefs.everPairedKey)
        notice = "Pairing reset. Restart Bounce to finish."
    }

    private func resetAll() {
        guard BounceConstants.isDevelopmentBuild else { return }
        DevFeatures.resetPairing()
        DevFeatures.resetUserDefaults()
        do {
            try Self.moveDevDataAside()
            showQuitPrompt = true
        } catch {
            notice = "Could not move dev data aside: \(error.localizedDescription)"
        }
    }

    /// Renames "Bounce Dev" to "Bounce Dev-backup-<timestamp>". Never deletes.
    private static func moveDevDataAside() throws {
        guard BounceConstants.isDevelopmentBuild else { return }
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent(BounceConstants.applicationSupportDirectoryName, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = appSupport.appendingPathComponent(
            "\(BounceConstants.applicationSupportDirectoryName)-backup-\(formatter.string(from: Date()))",
            isDirectory: true
        )
        try fm.moveItem(at: dir, to: target)
    }
}
