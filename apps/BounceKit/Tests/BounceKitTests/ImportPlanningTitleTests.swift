import XCTest
@testable import BounceKit

/// Locks in the filename → mix/version detection convention:
/// a `<track name> <major>.<minor>` suffix (e.g. `Song 1.01`), with the label stored
/// verbatim and a fallback of nothing detected (the sender autofills `N.00` on commit).
final class ImportPlanningTitleTests: XCTestCase {

    // MARK: - Regression: reported failing filename

    func testReportedFilenameDetectsMixNumberAndStripsStrayFragment() {
        let parsed = ImportPlanning.parseImportTitle(from: "die motions 1.01wav.mp3")

        XCTAssertTrue(parsed.hasDetectedVersion)
        XCTAssertEqual(parsed.detectedVersionLabel, "1.01")
        XCTAssertEqual(parsed.detectedTrackName, "die motions")
        XCTAssertFalse(parsed.mixVsVersionAmbiguous)
    }

    func testReportedFilenamePopulatesMixNumberMetadata() {
        XCTAssertEqual(ImportPlanning.parseMixNumber(from: "die motions 1.01wav.mp3"), "1.01")
    }

    // MARK: - Version followed directly by letters

    func testVersionFollowedDirectlyByFormatLetters() {
        let cases: [(String, String, String)] = [
            ("die motions 1.01wav.mp3", "die motions", "1.01"),
            ("summer thing 2.03wav.wav", "summer thing", "2.03"),
            ("summer thing 2.03WAV.wav", "summer thing", "2.03"),
            ("summer thing 2.03aiff.aiff", "summer thing", "2.03"),
        ]

        for (filename, trackName, label) in cases {
            let parsed = ImportPlanning.parseImportTitle(from: filename)
            XCTAssertTrue(parsed.hasDetectedVersion, filename)
            XCTAssertEqual(parsed.detectedVersionLabel, label, filename)
            XCTAssertEqual(parsed.detectedTrackName, trackName, filename)
        }
    }

    // MARK: - Normal separators still work

    func testVersionWithNormalSeparators() {
        let cases: [(String, String, String)] = [
            ("summer thing 3.02.wav", "summer thing", "3.02"),
            ("summer_thing_3.02.wav", "summer thing", "3.02"),
            ("summer thing (3.02).wav", "summer thing", "3.02"),
        ]

        for (filename, trackName, label) in cases {
            let parsed = ImportPlanning.parseImportTitle(from: filename)
            XCTAssertTrue(parsed.hasDetectedVersion, filename)
            XCTAssertEqual(parsed.detectedVersionLabel, label, filename)
            XCTAssertEqual(parsed.detectedTrackName, trackName, filename)
        }
    }

    // MARK: - No version at all

    func testNoVersionLeavesDetectionEmpty() {
        let parsed = ImportPlanning.parseImportTitle(from: "plain track.mp3")

        XCTAssertFalse(parsed.hasDetectedVersion)
        XCTAssertEqual(parsed.detectedVersionLabel, "")
        XCTAssertEqual(parsed.detectedTrackName, "plain track")
        XCTAssertNil(ImportPlanning.parseMixNumber(from: "plain track.mp3"))
        // The "N.00" label seen in the app is minted later by ImportCoordinator.makeVersionLabel
        // (first version of a new track → "1.00"), not by filename parsing.
    }

    // MARK: - Multiple numeric tokens

    func testMultipleNumericTokensUseTrailingMixNumber() {
        let parsed = ImportPlanning.parseImportTitle(from: "take 1 3.02.wav")

        XCTAssertTrue(parsed.hasDetectedVersion)
        XCTAssertEqual(parsed.detectedVersionLabel, "3.02")
        XCTAssertEqual(parsed.detectedTrackName, "take 1")
    }

    func testParseMixNumberFindsTokenWithoutTrailingMixSuffix() {
        XCTAssertEqual(ImportPlanning.parseMixNumber(from: "mix 2.5 tune.wav"), "2.5")
    }

    // MARK: - Version at start vs end of the name

    func testVersionAtEndOfName() {
        let parsed = ImportPlanning.parseImportTitle(from: "late night 3.02.wav")
        XCTAssertTrue(parsed.hasDetectedVersion)
        XCTAssertEqual(parsed.detectedVersionLabel, "3.02")
        XCTAssertEqual(parsed.detectedTrackName, "late night")
    }

    func testVersionAtStartOfNameIsNotTreatedAsSuffix() {
        // The convention only recognises a trailing mix-number suffix. A leading
        // `3.02` stays part of the track name for the label pass, but the loose
        // metadata extractor still finds the token.
        let parsed = ImportPlanning.parseImportTitle(from: "3.02 late night.wav")
        XCTAssertFalse(parsed.hasDetectedVersion)
        XCTAssertEqual(parsed.detectedVersionLabel, "")
        XCTAssertEqual(parsed.detectedTrackName, "3.02 late night")
        XCTAssertEqual(ImportPlanning.parseMixNumber(from: "3.02 late night.wav"), "3.02")
    }

    // MARK: - Two-decimal convention

    func testTwoDecimalMixNumberIsPreservedVerbatim() {
        let parsed = ImportPlanning.parseImportTitle(from: "late night 1.00.wav")
        XCTAssertEqual(parsed.detectedVersionLabel, "1.00")
    }

    // MARK: - Semantic suffixes are not stolen by the mix-number pass

    func testSemanticSuffixStillDetected() {
        let parsed = ImportPlanning.parseImportTitle(from: "summer thing demo.wav")
        XCTAssertTrue(parsed.hasDetectedVersion)
        XCTAssertEqual(parsed.detectedVersionLabel, "demo")
        XCTAssertEqual(parsed.detectedTrackName, "summer thing")
        XCTAssertFalse(parsed.mixVsVersionAmbiguous)
    }

    func testSemanticSuffixWithNumberStillAmbiguous() {
        let parsed = ImportPlanning.parseImportTitle(from: "summer thing final2.wav")
        XCTAssertTrue(parsed.hasDetectedVersion)
        XCTAssertEqual(parsed.detectedVersionLabel, "final2")
        XCTAssertEqual(parsed.detectedTrackName, "summer thing")
        XCTAssertTrue(parsed.mixVsVersionAmbiguous)
    }

    func testSeparatedSemanticWordIsNotConsumedByMixNumber() {
        let parsed = ImportPlanning.parseImportTitle(from: "summer thing 1.01 demo.wav")
        XCTAssertTrue(parsed.hasDetectedVersion)
        XCTAssertEqual(parsed.detectedVersionLabel, "demo")
        XCTAssertEqual(parsed.detectedTrackName, "summer thing 1.01")
    }

    // MARK: - Partial numeric token is not a match

    func testParseMixNumberRejectsPartialNumericToken() {
        XCTAssertNil(ImportPlanning.parseMixNumber(from: "song 1.011.mp3"))
    }

    // MARK: - Working-title match stops at word boundaries

    func testTitleMatchRequiresWholeWords() {
        XCTAssertTrue(ImportPlanning.titlesMatch("song", "song"))
        XCTAssertTrue(ImportPlanning.titlesMatch("song remix", "song"))
        XCTAssertTrue(ImportPlanning.titlesMatch("song", "song remix"))
        XCTAssertFalse(ImportPlanning.titlesMatch("songbird", "song"))
        XCTAssertFalse(ImportPlanning.titlesMatch("a", "always"))
    }
}
