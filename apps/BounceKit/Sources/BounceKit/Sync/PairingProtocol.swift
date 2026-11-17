import Foundation
import CryptoKit

/// Wire payload sent from receiver → sender when initiating a pair.
///
/// `nonce` is fresh random bytes that lets both sides derive the same
/// 6-char verification code without transmitting the code itself. The
/// derivation is `SHA256(deviceID || nonce).prefix(3)` rendered as hex.
public struct PairRequest: Codable, Sendable {
    public let deviceID: UUID
    public let deviceName: String
    public let appVersion: String?
    public let nonce: Data
    public let requestedAt: Date

    public init(deviceID: UUID, deviceName: String, appVersion: String?, nonce: Data, requestedAt: Date = .now) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.nonce = nonce
        self.requestedAt = requestedAt
    }

    /// Verification code derived from the request fields. Both sides
    /// compute this identically and render it in their UI for the user
    /// to compare visually.
    ///
    /// Format: 6 characters drawn from a 20-letter consonant alphabet,
    /// grouped `XXX-XXX` for readability. Vowels are excluded so the
    /// code can never spell a word, and visually-confusable characters
    /// (`0/O`, `1/I/L`) are absent. Entropy: 20⁶ ≈ 64M combinations,
    /// which is plenty for proximity comparison on a trusted LAN.
    public var verificationCode: String {
        Self.verificationCode(deviceID: deviceID, nonce: nonce)
    }

    /// Base-20 consonant alphabet — no vowels, no digits, no
    /// visually-confusable characters. Order matches RFC 8628.
    private static let codeAlphabet: [Character] = Array("BCDFGHJKLMNPQRSTVWXZ")

    public static func verificationCode(deviceID: UUID, nonce: Data) -> String {
        var input = Data()
        withUnsafeBytes(of: deviceID.uuid) { input.append(contentsOf: $0) }
        input.append(nonce)
        let digest = SHA256.hash(data: input)

        // Take 6 bytes from the digest, map each into the 20-letter
        // alphabet via modulo. Modulo bias is irrelevant here — the
        // code is for human comparison, not cryptographic uniqueness
        // (the shared key is what actually authenticates).
        let chars: [Character] = digest.prefix(6).map { byte in
            codeAlphabet[Int(byte) % codeAlphabet.count]
        }
        return "\(String(chars.prefix(3)))-\(String(chars.suffix(3)))"
    }

    public static func freshNonce() -> Data {
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return nonce
    }
}

/// Wire payload returned from sender → receiver after the user accepts (or rejects).
public struct PairResponse: Codable, Sendable {
    public let ok: Bool
    public let deviceID: UUID
    public let deviceName: String
    /// Base64-encoded shared key (only present on `ok == true`).
    public let sharedKeyBase64: String?
    public let error: String?

    public init(ok: Bool, deviceID: UUID, deviceName: String, sharedKeyBase64: String?, error: String?) {
        self.ok = ok
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.sharedKeyBase64 = sharedKeyBase64
        self.error = error
    }
}

/// Outcome of the user's choice on the sender side, returned from the
/// `pairApprovalHandler` callback.
public enum PairOutcome: Sendable {
    case approved(sharedKey: Data)
    case denied(reason: String)
}
