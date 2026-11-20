import XCTest
@testable import BounceKit

final class ImportPlanDuplicateTests: XCTestCase {
    private func item(exactDuplicate: Bool) -> ImportPlanItem {
        ImportPlanItem(
            sourceURL: URL(fileURLWithPath: "/tmp/song.wav"),
            originalTitle: "song",
            originalFilename: "song",
            detectedTrackName: "song",
            detectedVersionLabel: "",
            editableVersionLabel: "",
            hasDetectedVersion: false,
            matchKind: .none,
            mixVsVersionAmbiguous: false,
            sourceContentHash: "abc",
            isExactDuplicate: exactDuplicate,
            isNearDuplicate: false,
            skip: exactDuplicate
        )
    }

    private func plan(_ items: [ImportPlanItem]) -> ImportPlan {
        ImportPlan(
            availableTracks: [],
            groups: [ImportPlanGroup(target: .newTrack, editableTrackName: "song", items: items)]
        )
    }

    func testPlanOfOnlyExactDuplicatesIsFlagged() {
        XCTAssertTrue(plan([item(exactDuplicate: true), item(exactDuplicate: true)]).isEntirelyExactDuplicates)
    }

    func testMixedPlanIsNotFlagged() {
        XCTAssertFalse(plan([item(exactDuplicate: true), item(exactDuplicate: false)]).isEntirelyExactDuplicates)
    }

    func testEmptyPlanIsNotFlagged() {
        XCTAssertFalse(ImportPlan(availableTracks: [], groups: []).isEntirelyExactDuplicates)
    }

    func testExactDuplicateExplanation() {
        XCTAssertEqual(item(exactDuplicate: true).matchExplanation, "Already in library")
    }
}
