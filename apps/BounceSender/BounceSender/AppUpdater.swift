import AppKit
import Observation
import Sparkle
import BounceKit

@Observable
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let placeholderPublicKey = "SPARKLE_PUBLIC_KEY"

    private(set) var isStarted = false
    private(set) var availableVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    private static var hasRealPublicKey: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty && key != placeholderPublicKey
    }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func startForProductionBuilds() {
        guard !isStarted,
              Self.hasRealPublicKey,
              !BounceConstants.isDevelopmentBuild,
              !OnboardingShot.isActive else { return }
        controller.startUpdater()
        isStarted = true
    }

    func checkForUpdates() {
        guard isStarted else { return }
        controller.checkForUpdates(nil)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { availableVersion = nil }
    }
}
