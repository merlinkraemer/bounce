import XCTest
@testable import BounceKit

final class IdleWatchdogTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    func testDoesNotExpireBeforeIdleTimeout() {
        let watchdog = IdleWatchdog(idleTimeout: 10, now: start)
        XCTAssertFalse(watchdog.expireIfIdle(now: start.addingTimeInterval(9)))
        XCTAssertFalse(watchdog.didFire)
    }

    func testExpiresAfterIdleTimeout() {
        let watchdog = IdleWatchdog(idleTimeout: 10, now: start)
        XCTAssertTrue(watchdog.expireIfIdle(now: start.addingTimeInterval(10)))
        XCTAssertTrue(watchdog.didFire)
    }

    func testActivityRestartsTheTimeout() {
        let watchdog = IdleWatchdog(idleTimeout: 10, now: start)
        watchdog.touch(now: start.addingTimeInterval(8))
        watchdog.touch(now: start.addingTimeInterval(16))
        XCTAssertFalse(watchdog.expireIfIdle(now: start.addingTimeInterval(25)))
        XCTAssertTrue(watchdog.expireIfIdle(now: start.addingTimeInterval(26)))
    }

    func testStaysFiredAfterLateActivity() {
        let watchdog = IdleWatchdog(idleTimeout: 10, now: start)
        XCTAssertTrue(watchdog.expireIfIdle(now: start.addingTimeInterval(11)))
        watchdog.touch(now: start.addingTimeInterval(12))
        XCTAssertTrue(watchdog.didFire)
    }

    func testStartFiresOnExpire() async {
        let watchdog = IdleWatchdog(idleTimeout: 0.05)
        let fired = expectation(description: "expired")
        let task = watchdog.start { fired.fulfill() }
        await fulfillment(of: [fired], timeout: 2)
        task.cancel()
    }
}
