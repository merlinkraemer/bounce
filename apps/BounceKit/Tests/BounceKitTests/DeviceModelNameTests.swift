import XCTest
@testable import BounceKit

final class DeviceModelNameTests: XCTestCase {
    func testKnownModels() {
        XCTAssertEqual(DeviceModelName.marketingName(forMachine: "iPhone17,1"), "iPhone 16 Pro")
        XCTAssertEqual(DeviceModelName.marketingName(forMachine: "iPhone13,2"), "iPhone 12")
        XCTAssertEqual(DeviceModelName.marketingName(forMachine: "iPhone18,4"), "iPhone Air")
    }

    func testUnknownFallsBackToGenericWord() {
        XCTAssertEqual(DeviceModelName.marketingName(forMachine: "iPhone99,9"), "iPhone")
        XCTAssertEqual(DeviceModelName.marketingName(forMachine: "iPad14,1"), "iPad")
        XCTAssertEqual(DeviceModelName.marketingName(forMachine: ""), "iPhone")
    }

    func testResolveOrder() {
        XCTAssertEqual(DeviceModelName.resolve(custom: " Studio ", systemName: "Alex's iPhone", machine: "iPhone17,1"), "Studio")
        XCTAssertEqual(DeviceModelName.resolve(custom: "  ", systemName: "Alex's iPhone", machine: "iPhone17,1"), "Alex's iPhone")
        XCTAssertEqual(DeviceModelName.resolve(custom: nil, systemName: "iPhone", machine: "iPhone17,1"), "iPhone 16 Pro")
    }
}
