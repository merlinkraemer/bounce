import XCTest
@testable import BounceKit

final class ImportVersionLabelPrefillTests: XCTestCase {
    private func item(label: String) -> ImportPlanItem {
        ImportPlanItem(
            sourceURL: URL(fileURLWithPath: "/tmp/song.wav"),
            originalTitle: "song",
            originalFilename: "song",
            detectedTrackName: "song",
            detectedVersionLabel: label,
            editableVersionLabel: label,
            hasDetectedVersion: !label.isEmpty,
            matchKind: .none,
            mixVsVersionAmbiguous: false,
            sourceContentHash: UUID().uuidString,
            isExactDuplicate: false,
            isNearDuplicate: false,
            skip: false
        )
    }

    func testNewTrackSingleFileGetsFirstLabel() {
        var group = ImportPlanGroup(target: .newTrack, editableTrackName: "song", items: [item(label: "")])
        ImportPlanning.prefillVersionLabels(in: &group, existingLabels: [], style: .decimal)
        XCTAssertEqual(group.items[0].editableVersionLabel, "1.00")
    }

    func testExistingTrackContinuesNumberingAndSkipsTaken() {
        var group = ImportPlanGroup(target: .newTrack, editableTrackName: "song", items: [item(label: ""), item(label: "")])
        ImportPlanning.prefillVersionLabels(in: &group, existingLabels: ["1.00", "3.00"], style: .decimal)
        XCTAssertEqual(group.items.map(\.editableVersionLabel), ["4.00", "5.00"])
    }

    func testDetectedLabelIsKept() {
        var group = ImportPlanGroup(target: .newTrack, editableTrackName: "song", items: [item(label: "v2"), item(label: "")])
        ImportPlanning.prefillVersionLabels(in: &group, existingLabels: [], style: .prefixed)
        XCTAssertEqual(group.items.map(\.editableVersionLabel), ["v2", "v3"])
    }
}
