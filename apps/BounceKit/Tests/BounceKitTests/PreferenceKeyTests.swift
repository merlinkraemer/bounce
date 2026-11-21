import XCTest
@testable import BounceKit

/// Pins the persisted key strings and verifies store → read-back → default
/// behaviour for every key. If one of these assertions fails after a rename,
/// existing users would silently lose that preference.
final class PreferenceKeyTests: XCTestCase {
    private let suiteName = "BounceKitTests.PreferenceKeyTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRawKeyStringsAreUnchanged() {
        XCTAssertEqual(BouncePreferenceKey.allTracksSortMode, "allTracksSortMode")
        XCTAssertEqual(BouncePreferenceKey.detailsVisible, "bounce.mac.detailsVisible")
        XCTAssertEqual(BouncePreferenceKey.detailsVisibleByDefault, "bounce.mac.detailsVisibleByDefault")
        XCTAssertEqual(BouncePreferenceKey.inspectedVersionID, "bounce.mac.inspectedVersionID")
        XCTAssertEqual(BouncePreferenceKey.showReleasesTab, "bounce.mac.showReleasesTab")
        XCTAssertEqual(BouncePreferenceKey.showSetsTab, "bounce.mac.showSetsTab")
        XCTAssertEqual(BouncePreferenceKey.showMenuBarItem, "bounce.mac.showMenuBarItem")
        XCTAssertEqual(BouncePreferenceKey.lastPlayedVersionID, "lastPlayedVersionID")
        XCTAssertEqual(BouncePreferenceKey.senderDeviceID, "com.bounce.sync.senderDeviceID")
        XCTAssertEqual(BouncePreferenceKey.receiverDeviceID, "com.bounce.sync.receiverDeviceID")
        XCTAssertEqual(BouncePreferenceKey.legacySenderDeviceID, "com.bounce.senderID")
        XCTAssertEqual(BouncePreferenceKey.autoConnectPaused, "com.bounce.autoConnectPaused")
        XCTAssertEqual(BouncePreferenceKey.receiverDeviceName, "com.bounce.sync.receiverDeviceName")
        XCTAssertEqual(BouncePreferenceKey.senderListenerPort, "com.bounce.sync.senderListenerPort")
        XCTAssertEqual(BouncePreferenceKey.directSenderRoute, "com.bounce.sync.directSenderRoute")
    }

    func testBooleanRoundTripAndDefaultWhenUnset() {
        let cases: [(key: String, fallback: Bool)] = [
            (BouncePreferenceKey.detailsVisible, BouncePreferenceDefault.detailsVisible),
            (BouncePreferenceKey.detailsVisibleByDefault, BouncePreferenceDefault.detailsVisibleByDefault),
            (BouncePreferenceKey.showReleasesTab, BouncePreferenceDefault.showReleasesTab),
            (BouncePreferenceKey.showSetsTab, BouncePreferenceDefault.showSetsTab),
            (BouncePreferenceKey.showMenuBarItem, BouncePreferenceDefault.showMenuBarItem)
        ]

        for testCase in cases {
            XCTAssertNil(defaults.object(forKey: testCase.key), "\(testCase.key) unexpectedly set")
            XCTAssertEqual(defaults.object(forKey: testCase.key) as? Bool ?? testCase.fallback,
                           testCase.fallback)

            defaults.set(true, forKey: testCase.key)
            XCTAssertEqual(defaults.bool(forKey: testCase.key), true)

            defaults.set(false, forKey: testCase.key)
            XCTAssertEqual(defaults.bool(forKey: testCase.key), false)
        }
    }

    func testStringRoundTripAndDefaultWhenUnset() {
        let cases: [(key: String, value: String, fallback: String)] = [
            (BouncePreferenceKey.allTracksSortMode, AllTracksSortMode.name.rawValue,
             BouncePreferenceDefault.allTracksSortMode),
            (BouncePreferenceKey.inspectedVersionID, UUID().uuidString, ""),
            (BouncePreferenceKey.lastPlayedVersionID, UUID().uuidString, ""),
            (BouncePreferenceKey.senderDeviceID, UUID().uuidString, ""),
            (BouncePreferenceKey.receiverDeviceID, UUID().uuidString, ""),
            (BouncePreferenceKey.legacySenderDeviceID, UUID().uuidString, "")
        ]

        for testCase in cases {
            XCTAssertNil(defaults.string(forKey: testCase.key), "\(testCase.key) unexpectedly set")
            XCTAssertEqual(defaults.string(forKey: testCase.key) ?? testCase.fallback,
                           testCase.fallback)

            defaults.set(testCase.value, forKey: testCase.key)
            XCTAssertEqual(defaults.string(forKey: testCase.key), testCase.value)
        }
    }

    func testSortModeDefaultsAreValidRawValues() {
        XCTAssertEqual(BouncePreferenceDefault.allTracksSortMode, AllTracksSortMode.dateAdded.rawValue)
    }
}
