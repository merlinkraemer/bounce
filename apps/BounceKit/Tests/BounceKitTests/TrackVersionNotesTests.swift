import XCTest
import SwiftData
@testable import BounceKit

@MainActor
final class TrackVersionNotesTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = try ModelContainer(
            for: Track.self, Version.self, Note.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
    }

    private func addNote(to track: Track, versionID: UUID?, deleted: Bool = false) -> Note {
        let note = Note(trackID: track.id, versionID: versionID, type: .text, content: "n", createdOn: .phone, isSoftDeleted: deleted)
        context.insert(note)
        track.notes.append(note)
        return note
    }

    func testScopesToVersionPlusUnversionedAndSkipsDeleted() throws {
        let track = Track(name: "4")
        context.insert(track)
        let v1 = UUID(), v3 = UUID()
        let onV1 = addNote(to: track, versionID: v1)
        let onV3 = addNote(to: track, versionID: v3)
        let legacy = addNote(to: track, versionID: nil)
        _ = addNote(to: track, versionID: v1, deleted: true)
        try context.save()

        XCTAssertEqual(Set(track.visibleNotes(forVersion: v1).map(\.id)), [onV1.id, legacy.id])
        XCTAssertEqual(Set(track.visibleNotes(forVersion: v3).map(\.id)), [onV3.id, legacy.id])
        XCTAssertEqual(track.visibleNotes(forVersion: UUID()).map(\.id), [legacy.id])
    }

    func testVersionWithoutNotesIsEmptyEvenWhenTrackHasNotes() throws {
        let track = Track(name: "4")
        context.insert(track)
        _ = addNote(to: track, versionID: UUID())
        try context.save()

        XCTAssertFalse(track.visibleNotes.isEmpty)
        XCTAssertTrue(track.visibleNotes(forVersion: UUID()).isEmpty)
    }
}
