import XCTest
@testable import BounceKit

final class DirectSenderRouteTests: XCTestCase {
    private let macID = UUID(uuidString: "9B2C0E7A-4D61-4C3B-8F50-1A2B3C4D5E6F")!

    func testDropsInvalidAndDuplicateHostsAndCaps() {
        let route = DirectSenderRoute(
            macDeviceID: macID,
            hosts: ["10.0.0.1", "10.0.0.1", "mac.local", "10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5"],
            port: 4000
        )
        XCTAssertEqual(route.hosts, ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4"])
        XCTAssertEqual(route.endpoints.count, 4)
    }

    func testPreferringMovesHostFirstAndUpdatesPort() {
        let route = DirectSenderRoute(macDeviceID: macID, hosts: ["10.0.0.1", "172.20.10.2"], port: 4000)
        let refreshed = route.preferring("172.20.10.2", port: 5000)
        XCTAssertEqual(refreshed.hosts, ["172.20.10.2", "10.0.0.1"])
        XCTAssertEqual(refreshed.port, 5000)
        XCTAssertEqual(route.preferring(nil, port: 4000), route)
    }

    func testSaveAndLoadRoundTrip() {
        let suite = "BounceKitTests.DirectSenderRouteTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(DirectSenderRoute.load(from: defaults))
        let route = DirectSenderRoute(macDeviceID: macID, hosts: ["172.20.10.2"], port: 4000)
        route.save(to: defaults)
        XCTAssertEqual(DirectSenderRoute.load(from: defaults), route)
    }

    func testShareableAddressFilter() {
        XCTAssertTrue(LocalNetworkAddresses.isShareable(host: "172.20.10.2", interface: "en0"))
        XCTAssertTrue(LocalNetworkAddresses.isShareable(host: "192.168.1.20", interface: "en7"))
        XCTAssertFalse(LocalNetworkAddresses.isShareable(host: "127.0.0.1", interface: "en0"))
        XCTAssertFalse(LocalNetworkAddresses.isShareable(host: "169.254.3.4", interface: "en0"))
        XCTAssertFalse(LocalNetworkAddresses.isShareable(host: "100.64.0.1", interface: "utun3"))
        XCTAssertFalse(LocalNetworkAddresses.isShareable(host: "fe80::1", interface: "en0"))
    }
}
