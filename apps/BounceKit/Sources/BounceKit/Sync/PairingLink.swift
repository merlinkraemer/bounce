import Foundation
import Network
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
/// Production QRs are universal links with the payload in the URL fragment, so
/// the token and Mac name never reach the web server. Development QRs and Mac
/// 1.0.0 QRs use the custom scheme with the payload as the query.
/// `hosts` and `port` are optional direct addresses of the Mac's sync listener
/// for networks where Bonjour does not reach the phone (iPhone hotspot). Apps
/// that predate them ignore the extra keys.
public struct PairingLink: Equatable, Hashable, Sendable, Identifiable {
    public static let currentVersion = 1
    public static let maxHostCount = 4

    public let version: Int
    public let macDeviceID: UUID
    public let macName: String
    public let token: String
    public let expiresAt: Date
    public let hosts: [String]
    public let port: UInt16?
    public let lane: PairingLane

    public var id: String { token }

    public init(
        version: Int = PairingLink.currentVersion,
        macDeviceID: UUID,
        macName: String,
        token: String,
        expiresAt: Date,
        hosts: [String] = [],
        port: UInt16? = nil,
        lane: PairingLane = .current
    ) {
        self.version = version
        self.macDeviceID = macDeviceID
        self.macName = macName
        self.token = token
        self.expiresAt = expiresAt
        let validHosts = Array(hosts.filter(Self.isDirectHost).prefix(Self.maxHostCount))
        let validPort = port.flatMap { $0 == 0 ? nil : $0 }
        self.hosts = validPort == nil ? [] : validHosts
        self.port = validHosts.isEmpty ? nil : validPort
        self.lane = lane
    }

    public var directRoute: DirectSenderRoute? {
        guard let port, !hosts.isEmpty else { return nil }
        return DirectSenderRoute(macDeviceID: macDeviceID, hosts: hosts, port: port)
    }

    static func isDirectHost(_ host: String) -> Bool {
        IPv4Address(host) != nil || (IPv6Address(host) != nil && !host.contains("%"))
    }

    public func isExpired(at date: Date = .now) -> Bool {
        date >= expiresAt
    }

    private var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "i", value: macDeviceID.uuidString),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "e", value: String(Int(expiresAt.timeIntervalSince1970)))
        ] + directQueryItems
    }

    private var directQueryItems: [URLQueryItem] {
        guard let port, !hosts.isEmpty else { return [] }
        return [
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: String(port))
        ]
    }

    public var url: URL {
        var components = URLComponents()
        switch lane {
        case .production:
            components.scheme = "https"
            components.host = BounceConstants.pairingLinkHost
            components.path = BounceConstants.pairingLinkPath
            var payload = URLComponents()
            payload.queryItems = queryItems
            components.percentEncodedFragment = payload.percentEncodedQuery
        case .development:
            components.scheme = lane.urlScheme
            components.host = "pair"
            components.queryItems = queryItems
        }
        return components.url!
    }

    public static func parse(_ url: URL, lane: PairingLane = .current) throws -> PairingLink {
        guard let scheme = url.scheme?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PairingLinkError.notAPairingLink
        }
        let payload: [URLQueryItem]
        if scheme == "https" {
            guard let host = url.host?.lowercased(),
                  host == BounceConstants.pairingLinkHost || host == "www." + BounceConstants.pairingLinkHost,
                  components.path == BounceConstants.pairingLinkPath
                    || components.path == BounceConstants.pairingLinkPath + "/" else {
                throw PairingLinkError.notAPairingLink
            }
            guard lane == .production else { throw PairingLinkError.laneMismatch }
            var fragment = URLComponents()
            fragment.percentEncodedQuery = components.percentEncodedFragment
            payload = fragment.queryItems ?? []
        } else {
            guard scheme == PairingLane.production.urlScheme || scheme == PairingLane.development.urlScheme else {
                throw PairingLinkError.notAPairingLink
            }
            guard scheme == lane.urlScheme else { throw PairingLinkError.laneMismatch }
            guard url.host?.lowercased() == "pair" else { throw PairingLinkError.notAPairingLink }
            payload = components.queryItems ?? []
        }
        var values: [String: String] = [:]
        for item in payload {
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
            hosts: values["h"]?.split(separator: ",").map(String.init) ?? [],
            port: values["p"].flatMap(UInt16.init),
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
