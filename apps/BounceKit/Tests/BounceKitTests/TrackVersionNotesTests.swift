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

    private func addVersion(to track: Track, addedAt: Date) -> Version {
        let version = Version(trackID: track.id, label: "v", filePath: "p", fileSize: 0, fileFormat: "wav", originalFilename: "f", duration: 1, addedAt: addedAt)
        context.insert(version)
        track.versions.append(version)
        return version
    }

    func testScopesToVersionAndPutsUnversionedOnFirstVersionOnly() throws {
        let track = Track(name: "4")
        context.insert(track)
        let v2 = addVersion(to: track, addedAt: Date(timeIntervalSince1970: 200))
        let v1 = addVersion(to: track, addedAt: Date(timeIntervalSince1970: 100))
        let v3 = addVersion(to: track, addedAt: Date(timeIntervalSince1970: 300))
        let onV1 = addNote(to: track, versionID: v1.id)
        let onV3 = addNote(to: track, versionID: v3.id)
        let legacy = addNote(to: track, versionID: nil)
        _ = addNote(to: track, versionID: v1.id, deleted: true)
        _ = addNote(to: track, versionID: nil, deleted: true)
        try context.save()

        XCTAssertEqual(Set(track.visibleNotes(forVersion: v1.id).map(\.id)), [onV1.id, legacy.id])
        XCTAssertEqual(track.visibleNotes(forVersion: v2.id).map(\.id), [])
        XCTAssertEqual(track.visibleNotes(forVersion: v3.id).map(\.id), [onV3.id])
        XCTAssertEqual(track.visibleNotes(forVersion: UUID()).map(\.id), [])
        XCTAssertEqual(track.owningVersionID(of: legacy), v1.id)
        XCTAssertEqual(track.owningVersionID(of: onV3), v3.id)
    }

    func testSingleVersionShowsItsNotesAndUnversionedNotes() throws {
        let track = Track(name: "4")
        context.insert(track)
        let only = addVersion(to: track, addedAt: Date(timeIntervalSince1970: 100))
        let own = addNote(to: track, versionID: only.id)
        let legacy = addNote(to: track, versionID: nil)
        try context.save()

        XCTAssertEqual(Set(track.visibleNotes(forVersion: only.id).map(\.id)), [own.id, legacy.id])
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
