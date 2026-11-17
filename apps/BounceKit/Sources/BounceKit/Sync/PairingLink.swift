import Foundation
import Security

public enum PairingLane: Sendable, Equatable {
    case production
    case development

    public static var current: PairingLane {
        BounceConstants.isDevelopmentBuild ? .development : .production
    }

    public var urlScheme: String {
        switch self {
        case .production: "bounce"
        case .development: "bounce-dev"
        }
    }
}

public enum PairingLinkError: Error, Equatable {
    case notAPairingLink
    case laneMismatch
    case unsupportedVersion(Int)
    case malformed
}

/// What the Mac encodes in its pairing QR: which Mac to pair with and a
/// short-lived single-use token proving the phone saw the Mac's screen.
/// The payload is the query string only, so it can move to an https URL
/// unchanged.
public struct PairingLink: Equatable, Hashable, Sendable, Identifiable {
    public static let currentVersion = 1

    public let version: Int
    public let macDeviceID: UUID
    public let macName: String
    public let token: String
    public let expiresAt: Date
    public let lane: PairingLane

    public var id: String { token }

    public init(
        version: Int = PairingLink.currentVersion,
        macDeviceID: UUID,
        macName: String,
        token: String,
        expiresAt: Date,
        lane: PairingLane = .current
    ) {
        self.version = version
        self.macDeviceID = macDeviceID
        self.macName = macName
        self.token = token
        self.expiresAt = expiresAt
        self.lane = lane
    }

    public func isExpired(at date: Date = .now) -> Bool {
        date >= expiresAt
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = lane.urlScheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "i", value: macDeviceID.uuidString),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "e", value: String(Int(expiresAt.timeIntervalSince1970)))
        ]
        return components.url!
    }

    public static func parse(_ url: URL, lane: PairingLane = .current) throws -> PairingLink {
        guard let scheme = url.scheme?.lowercased(),
              scheme == PairingLane.production.urlScheme || scheme == PairingLane.development.urlScheme else {
            throw PairingLinkError.notAPairingLink
        }
        guard scheme == lane.urlScheme else { throw PairingLinkError.laneMismatch }
        guard url.host?.lowercased() == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PairingLinkError.notAPairingLink
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, values[item.name] == nil else { throw PairingLinkError.malformed }
            values[item.name] = value
        }
        guard let rawVersion = values["v"], let version = Int(rawVersion) else { throw PairingLinkError.malformed }
        guard version == currentVersion else { throw PairingLinkError.unsupportedVersion(version) }
        guard let rawID = values["i"], let macDeviceID = UUID(uuidString: rawID),
              let macName = values["n"], !macName.isEmpty,
              let token = values["t"], PairingToken.isWellFormed(token),
              let rawExpiry = values["e"], let expiry = TimeInterval(rawExpiry) else {
            throw PairingLinkError.malformed
        }
        return PairingLink(
            version: version,
            macDeviceID: macDeviceID,
            macName: macName,
            token: token,
            expiresAt: Date(timeIntervalSince1970: expiry),
            lane: lane
        )
    }
}

public enum PairingToken {
    public static let byteCount = 16
    static let encodedLength = 22

    public static func generate() -> String {
        var bytes = Data(count: byteCount)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.base64URLEncodedString()
    }

    public static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == encodedLength && token.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        var difference = lhs.count ^ rhs.count
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= Int(left ^ right)
        }
        return difference == 0
    }
}

/// Sender-side issuer: one live token at a time, rotated when it expires or
/// is used. A token is accepted at most once.
public struct PairingTokenIssuer: Sendable {
    public static let defaultLifetime: TimeInterval = 5 * 60

    public private(set) var token: String
    public private(set) var expiresAt: Date
    private let lifetime: TimeInterval

    public init(lifetime: TimeInterval = PairingTokenIssuer.defaultLifetime, now: Date = .now) {
        self.lifetime = lifetime
        self.token = PairingToken.generate()
        self.expiresAt = now.addingTimeInterval(lifetime)
    }

    public mutating func rotate(now: Date = .now) {
        token = PairingToken.generate()
        expiresAt = now.addingTimeInterval(lifetime)
    }

    @discardableResult
    public mutating func rotateIfExpired(now: Date = .now) -> Bool {
        guard now >= expiresAt else { return false }
        rotate(now: now)
        return true
    }

    /// Returns true and rotates the token when `presented` is the current,
    /// unexpired token. Anything else leaves the live token untouched.
    public mutating func consume(_ presented: String, now: Date = .now) -> Bool {
        guard now < expiresAt, PairingToken.constantTimeEquals(presented, token) else { return false }
        rotate(now: now)
        return true
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
