import XCTest
@testable import BounceKit

final class RecordingDateTests: XCTestCase {
    func testConservativeDateInference() {
        let cases: [(String, String?)] = [
            ("Live 11.11.11 set", "2011-11-11"),
            ("Live 11-11-11 set", "2011-11-11"),
            ("Live 111111 set", "2011-11-11"),
            ("Live 01-02-03 set", nil),
            ("Live 31-02-24 set", nil),
            ("Live 29.02.24 set", "2024-02-29"),
            ("Live 29.02.23 set", nil),
            ("Live 01-01-70 set", "1970-01-01"),
            ("Live 01-01-69 set", "2069-01-01"),
            ("Mix 2024-01-02 exported 2024-01-03", nil),
            ("Mix 2024-01-02", "2024-01-02"),
            ("Mix 010224_1", "2024-02-01"),
            ("Live 12-11-11 set", nil),
            ("Live 31-12-99 set", "1999-12-31"),
            ("No date in this title", nil),
            ("Set 1234567", nil)
        ]

        for (title, expected) in cases {
            XCTAssertEqual(RecordingDate.infer(from: title), expected, title)
        }
    }

    func testExplicitAndFourDigitDates() {
        XCTAssertEqual(RecordingDate.infer(from: "2026-09-11 mix"), "2026-09-11")
        XCTAssertEqual(RecordingDate.infer(from: "11.09.2026 mix"), "2026-09-11")
        XCTAssertEqual(RecordingDate.infer(from: "31.12.1969 mix"), "1969-12-31")
        XCTAssertNil(RecordingDate.validate("2026-02-29"))
        XCTAssertEqual(RecordingDate.validate("2024-02-29"), "2024-02-29")
    }

    func testDateOnlyRoundTripsInDifferentTimeZones() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = try! XCTUnwrap(RecordingDate.date(from: "2026-09-11", calendar: pacific))

        XCTAssertEqual(RecordingDate.string(from: date, calendar: pacific), "2026-09-11")
        XCTAssertNotEqual(RecordingDate.string(from: date, calendar: Calendar(identifier: .gregorian)), "2026-09-10")
    }

    func testRecordingDateChangesManifestFingerprint() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_789_084_800)
        var withoutDate = TrackManifestEntry(
            id: id,
            name: "Set",
            createdAt: now,
            updatedAt: now,
            revision: 1,
            versions: []
        )
        let initial = LibraryManifest.generationFingerprint(
            tracks: [withoutDate], notes: [], playlistFolders: [], playlists: []
        )

        withoutDate.recordingDateString = "2026-09-11"
        let changed = LibraryManifest.generationFingerprint(
            tracks: [withoutDate], notes: [], playlistFolders: [], playlists: []
        )
        XCTAssertNotEqual(initial, changed)
    }

    func testLegacyManifestDateDefaultsToNil() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"Song","updatedAt":1789084800,"versions":[]}
        """.data(using: .utf8)!
        let value = try JSONDecoder().decode(TrackManifestEntry.self, from: json)
        XCTAssertNil(value.recordingDateString)
    }

    func testManifestCarriesCanonicalDateAndRejectsInvalidValues() throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_789_084_800)
        let entry = TrackManifestEntry(
            id: id,
            name: "Set",
            createdAt: now,
            updatedAt: now,
            revision: 1,
            versions: [],
            recordingDateString: "2024-02-29"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoded = try JSONDecoder().decode(
            TrackManifestEntry.self,
            from: encoder.encode(entry)
        )
        XCTAssertEqual(decoded.recordingDateString, "2024-02-29")

        let invalid = TrackManifestEntry(
            id: id,
            name: "Set",
            createdAt: now,
            updatedAt: now,
            revision: 1,
            versions: [],
            recordingDateString: "2024-02-30"
        )
        XCTAssertNil(invalid.recordingDateString)
    }
}
