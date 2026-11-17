import XCTest
import CoreGraphics
@testable import BounceKit

final class CatalogueLayoutTests: XCTestCase {

    // MARK: - Title strip sizing

    private let strip = TitleStripSizing()

    func testShortMetadataLeavesCoverAtMinimumSide() {
        let size = strip.sizeThatFits(proposalWidth: 600) { _ in 40 }

        XCTAssertEqual(size.width, 600)
        XCTAssertEqual(size.height, 72)
    }

    func testLongMetadataGrowsCoverToMatchInfoStack() {
        let pair = strip.resolvedPair(width: 600) { _ in 180 }
        let size = strip.sizeThatFits(proposalWidth: 600) { _ in 180 }

        XCTAssertEqual(pair.side, 180)
        XCTAssertEqual(pair.height, 180)
        XCTAssertEqual(size.width, 600)
        XCTAssertEqual(size.height, 180)
    }

    func testLongMetadataIsMeasuredAtTheSettledTextWidth() {
        var measuredWidths: [CGFloat] = []
        let pair = strip.resolvedPair(width: 600) { infoWidth in
            measuredWidths.append(infoWidth)
            return 180
        }

        XCTAssertEqual(pair.side, 180)
        // The info stack sits beside a 180pt cover with 16pt spacing.
        XCTAssertEqual(measuredWidths.last, 600 - 16 - 180)
    }

    func testWrappingMetadataExhaustingIterationsStillCoversFinalMeasurement() {
        // Height grows as the text column narrows, so the cover keeps chasing
        // the stack for all 8 iterations; the consistency check must report
        // the height measured at the final placed width, not at minSide.
        let pair = strip.resolvedPair(width: 600) { infoWidth in
            600 - infoWidth
        }

        XCTAssertEqual(pair.side, 200)
        XCTAssertEqual(pair.height, 216)
    }

    func testNarrowWidthClampsInfoColumnToItsMinimum() {
        // infoWidth = max(40, 100 - 16 - 72) = 40 even though the cover is
        // wider than the strip; the width contract is preserved.
        let pair = strip.resolvedPair(width: 100) { _ in 300 }
        let size = strip.sizeThatFits(proposalWidth: 100) { _ in 300 }

        XCTAssertEqual(pair.side, 300)
        XCTAssertEqual(pair.height, 300)
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 300)
    }

    func testMissingProposalWidthUsesFallback() {
        let size = strip.sizeThatFits(proposalWidth: nil) { _ in 40 }

        XCTAssertEqual(size.width, 600)
        XCTAssertEqual(size.height, 72)
    }

    func testCustomMetricsShiftResolution() {
        let sizing = TitleStripSizing(spacing: 8, minSide: 100, minInfoWidth: 20)
        let pair = sizing.resolvedPair(width: 500) { _ in 140 }

        XCTAssertEqual(pair.side, 140)
        XCTAssertEqual(pair.height, 140)
    }

    // MARK: - Column visibility thresholds

    func testColumnVisibilityAtWideWidth() {
        XCTAssertTrue(LibraryColumnVisibilityRules.showsAdded(atWidth: 600))
        XCTAssertTrue(LibraryColumnVisibilityRules.showsDuration(atWidth: 600))
        XCTAssertFalse(LibraryColumnVisibilityRules.foldsMixIntoSubtitle(atWidth: 600))
    }

    func testAddedColumnThreshold() {
        XCTAssertFalse(LibraryColumnVisibilityRules.showsAdded(atWidth: 559))
        XCTAssertTrue(LibraryColumnVisibilityRules.showsAdded(atWidth: 560))
        XCTAssertTrue(LibraryColumnVisibilityRules.showsAdded(atWidth: 561))
    }

    func testDurationColumnThreshold() {
        XCTAssertFalse(LibraryColumnVisibilityRules.showsDuration(atWidth: 479))
        XCTAssertTrue(LibraryColumnVisibilityRules.showsDuration(atWidth: 480))
        XCTAssertTrue(LibraryColumnVisibilityRules.showsDuration(atWidth: 481))
    }

    func testMixFoldThreshold() {
        XCTAssertTrue(LibraryColumnVisibilityRules.foldsMixIntoSubtitle(atWidth: 399))
        XCTAssertFalse(LibraryColumnVisibilityRules.foldsMixIntoSubtitle(atWidth: 400))
        XCTAssertFalse(LibraryColumnVisibilityRules.foldsMixIntoSubtitle(atWidth: 401))
    }

    // MARK: - Header height cache

    func testUnknownKeysReadAsZero() {
        let cache = HeaderHeightCache()

        XCTAssertEqual(cache.height(for: HeaderHeightCache.libraryKey), 0)
        XCTAssertEqual(cache.height(for: HeaderHeightCache.setsKey), 0)
        XCTAssertEqual(cache.height(for: HeaderHeightCache.playlistKey(UUID())), 0)
    }

    func testStoredHeightIsReadBackPerKey() {
        let cache = HeaderHeightCache()
        let playlistID = UUID()

        cache.store(123, for: HeaderHeightCache.libraryKey)
        cache.store(58, for: HeaderHeightCache.playlistKey(playlistID))

        XCTAssertEqual(cache.height(for: HeaderHeightCache.libraryKey), 123)
        XCTAssertEqual(cache.height(for: HeaderHeightCache.playlistKey(playlistID)), 58)
        XCTAssertEqual(cache.height(for: HeaderHeightCache.setsKey), 0)
    }

    func testStoreInvalidatesPreviousValue() {
        let cache = HeaderHeightCache()

        cache.store(80, for: HeaderHeightCache.libraryKey)
        cache.store(123, for: HeaderHeightCache.libraryKey)

        XCTAssertEqual(cache.height(for: HeaderHeightCache.libraryKey), 123)
    }

    func testCacheInstancesAreIsolated() {
        let first = HeaderHeightCache()
        let second = HeaderHeightCache()

        first.store(90, for: HeaderHeightCache.setsKey)

        XCTAssertEqual(first.height(for: HeaderHeightCache.setsKey), 90)
        XCTAssertEqual(second.height(for: HeaderHeightCache.setsKey), 0)
    }

    func testPlaylistKeysAreNamespacedPerSurface() {
        let first = UUID()
        let second = UUID()

        XCTAssertNotEqual(HeaderHeightCache.playlistKey(first), HeaderHeightCache.playlistKey(second))
        XCTAssertNotEqual(HeaderHeightCache.playlistKey(first), HeaderHeightCache.libraryKey)
        XCTAssertNotEqual(HeaderHeightCache.playlistKey(first), HeaderHeightCache.setsKey)
    }

    // MARK: - Sort mappings

    func testSortModeRawValueRoundTrips() {
        for mode in AllTracksSortMode.allCases {
            XCTAssertEqual(AllTracksSortMode(rawValue: mode.rawValue), mode)
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    func testSortModeCasesAndLabels() {
        XCTAssertEqual(AllTracksSortMode.allCases.map(\.rawValue), ["dateAdded", "name"])
        XCTAssertEqual(AllTracksSortMode.dateAdded.label, "Date Added")
        XCTAssertEqual(AllTracksSortMode.name.label, "Name")
    }

    func testDateAddedSortsNewestFirst() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let mode = AllTracksSortMode.dateAdded

        XCTAssertTrue(mode.precedes(lhsDate: newer, lhsName: "A", rhsDate: older, rhsName: "B"))
        XCTAssertFalse(mode.precedes(lhsDate: older, lhsName: "A", rhsDate: newer, rhsName: "B"))
        XCTAssertFalse(mode.precedes(lhsDate: older, lhsName: "A", rhsDate: older, rhsName: "B"))
    }

    func testNameSortsCaseInsensitively() {
        let date = Date(timeIntervalSince1970: 0)
        let mode = AllTracksSortMode.name

        XCTAssertTrue(mode.precedes(lhsDate: date, lhsName: "alpha", rhsDate: date, rhsName: "Beta"))
        XCTAssertFalse(mode.precedes(lhsDate: date, lhsName: "Beta", rhsDate: date, rhsName: "alpha"))
        XCTAssertFalse(mode.precedes(lhsDate: date, lhsName: "Same", rhsDate: date, rhsName: "same"))
    }

    func testSortModesProduceOppositeOrderForSameInput() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)

        XCTAssertTrue(AllTracksSortMode.dateAdded.precedes(lhsDate: newer, lhsName: "alpha", rhsDate: older, rhsName: "beta"))
        XCTAssertTrue(AllTracksSortMode.name.precedes(lhsDate: newer, lhsName: "alpha", rhsDate: older, rhsName: "beta"))
    }
}
