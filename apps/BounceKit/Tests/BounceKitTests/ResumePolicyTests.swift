import XCTest
@testable import BounceKit

final class ResumePolicyTests: XCTestCase {
    func testNonSetNeverResumes() {
        XCTAssertNil(ResumePolicy.resumePosition(isSet: false, saved: 120, duration: 300))
    }

    func testNonSetIgnoresLongSavedPosition() {
        XCTAssertNil(ResumePolicy.resumePosition(isSet: false, saved: 1200, duration: 3600))
    }

    func testOnlySetsAreTracked() {
        XCTAssertTrue(ResumePolicy.shouldTrack(isSet: true))
        XCTAssertFalse(ResumePolicy.shouldTrack(isSet: false))
    }

    func testSetResumesSavedPosition() {
        XCTAssertEqual(ResumePolicy.resumePosition(isSet: true, saved: 1200, duration: 3600), 1200)
    }

    func testSetIgnoresTinyOrNearEndPositions() {
        XCTAssertNil(ResumePolicy.resumePosition(isSet: true, saved: 2, duration: 3600))
        XCTAssertNil(ResumePolicy.resumePosition(isSet: true, saved: 3598, duration: 3600))
    }

    func testIsFinished() {
        XCTAssertTrue(ResumePolicy.isFinished(saved: 3598, duration: 3600))
        XCTAssertFalse(ResumePolicy.isFinished(saved: 100, duration: 3600))
        XCTAssertFalse(ResumePolicy.isFinished(saved: 0, duration: 3600))
    }
}
