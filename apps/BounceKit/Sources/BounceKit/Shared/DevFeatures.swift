import Foundation

/// Single gate for developer tools. Visible only in the development lane
/// (`.dev` bundle id); a production build never shows or runs them.
@MainActor
public enum DevFeatures {
    nonisolated public static var isEnabled: Bool { BounceConstants.isDevelopmentBuild }

    /// Clears this lane's pairing key, bonded peers and transport device IDs.
    /// Callers must also check `isDevelopmentBuild` at the call site.
    @discardableResult
    public static func resetPairing() -> Bool {
        guard BounceConstants.isDevelopmentBuild else { return false }
        BonjourTransport.resetLocalPairingState()
        return true
    }

    /// Clears the app's whole UserDefaults domain (dev lane only).
    @discardableResult
    public static func resetUserDefaults() -> Bool {
        guard BounceConstants.isDevelopmentBuild, let domain = Bundle.main.bundleIdentifier else { return false }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        return true
    }
}
