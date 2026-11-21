import Foundation
import Network

/// Addresses at which the receiver can reach the paired Mac's sync listener
/// without Bonjour. Learned from a pairing QR and refreshed whenever Bonjour
/// resolves the Mac.
public struct DirectSenderRoute: Codable, Equatable, Sendable {
    public let macDeviceID: UUID
    public let hosts: [String]
    public let port: UInt16

    public init(macDeviceID: UUID, hosts: [String], port: UInt16) {
        self.macDeviceID = macDeviceID
        var unique: [String] = []
        for host in hosts where PairingLink.isDirectHost(host) && !unique.contains(host) {
            unique.append(host)
        }
        self.hosts = Array(unique.prefix(PairingLink.maxHostCount))
        self.port = port
    }

    public var endpoints: [NWEndpoint] {
        guard let port = NWEndpoint.Port(rawValue: port) else { return [] }
        return hosts.map { .hostPort(host: NWEndpoint.Host($0), port: port) }
    }

    public func preferring(_ host: String?, port newPort: UInt16) -> DirectSenderRoute {
        DirectSenderRoute(macDeviceID: macDeviceID, hosts: [host].compactMap { $0 } + hosts, port: newPort)
    }

    public static func load(from defaults: UserDefaults = .standard) -> DirectSenderRoute? {
        guard let data = defaults.data(forKey: BouncePreferenceKey.directSenderRoute) else { return nil }
        return try? JSONDecoder().decode(DirectSenderRoute.self, from: data)
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: BouncePreferenceKey.directSenderRoute)
    }
}

/// Body of the Mac's unauthenticated `GET /identity`. Lets the receiver check
/// that a direct address still belongs to the paired Mac before it sends the
/// shared key or a pairing token there.
public struct SenderIdentity: Codable, Sendable {
    public let deviceID: UUID
    public let deviceName: String

    public init(deviceID: UUID, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}

/// Non-loopback, non-link-local IPv4 addresses of this Mac's up Ethernet-style
/// interfaces (`en*`: Wi-Fi, Ethernet, iPhone USB), for the pairing QR.
public enum LocalNetworkAddresses {
    public static func current() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(bitPattern: entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let interface = String(cString: entry.ifa_name)
            if isShareable(host: host, interface: interface), !result.contains(host) {
                result.append(host)
            }
        }
        return Array(result.prefix(PairingLink.maxHostCount))
    }

    static func isShareable(host: String, interface: String) -> Bool {
        interface.hasPrefix("en")
            && IPv4Address(host) != nil
            && !host.hasPrefix("127.")
            && !host.hasPrefix("169.254.")
    }
}
