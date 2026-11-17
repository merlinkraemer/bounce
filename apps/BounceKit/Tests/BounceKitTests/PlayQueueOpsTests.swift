import XCTest
@testable import BounceKit

final class PlayQueueOpsTests: XCTestCase {
    private struct Item: Equatable { let id = UUID(); let name: String }
    private func make(_ names: String...) -> [Item] { names.map { Item(name: $0) } }
    private func names(_ q: [Item]) -> [String] { q.map(\.name) }

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testAddToEmptyQueue() {
        var q: [Item] = []; var i = 5
        let a = Item(name: "a")
        PlayQueueOps.addToQueue(a, id: \.id, queue: &q, index: &i, queued: [])
        XCTAssertEqual(names(q), ["a"]); XCTAssertEqual(i, 0)
    }

    func testAddNewItemGoesRightAfterCurrentWhenNothingQueued() {
        var q = make("a", "b", "c"); var i = 0
        let x = Item(name: "x")
        XCTAssertTrue(PlayQueueOps.addToQueue(x, id: \.id, queue: &q, index: &i, queued: []))
        XCTAssertEqual(names(q), ["a", "x", "b", "c"]); XCTAssertEqual(i, 0)
    }

    func testAddGoesBehindUserQueuedEntriesInOrder() {
        var q = make("a", "b", "c"); var i = 0
        var queued: Set<UUID> = []
        let x = Item(name: "x"), y = Item(name: "y")
        PlayQueueOps.addToQueue(x, id: \.id, queue: &q, index: &i, queued: queued)
        queued.insert(x.id)
        PlayQueueOps.addToQueue(y, id: \.id, queue: &q, index: &i, queued: queued)
        XCTAssertEqual(names(q), ["a", "x", "y", "b", "c"])
    }

    func testAddContextItemAlreadyUpcomingMovesItForward() {
        var q = make("a", "b", "c", "d"); var i = 0
        XCTAssertTrue(PlayQueueOps.addToQueue(q[3], id: \.id, queue: &q, index: &i, queued: []))
        XCTAssertEqual(names(q), ["a", "d", "b", "c"]); XCTAssertEqual(i, 0)
    }

    func testAddAlreadyQueuedItemIsNoOp() {
        var q = make("a", "x", "b"); var i = 0
        XCTAssertFalse(PlayQueueOps.addToQueue(q[1], id: \.id, queue: &q, index: &i, queued: [q[1].id]))
        XCTAssertEqual(names(q), ["a", "x", "b"])
    }

    func testAddAlreadyPlayedItemMovesAfterCurrent() {
        var q = make("a", "b", "c"); var i = 1
        PlayQueueOps.addToQueue(q[0], id: \.id, queue: &q, index: &i, queued: [])
        XCTAssertEqual(names(q), ["b", "a", "c"]); XCTAssertEqual(i, 0)
        XCTAssertEqual(q[i].name, "b")
    }

    func testAddCurrentItemIsNoOp() {
        var q = make("a", "b"); var i = 1
        XCTAssertFalse(PlayQueueOps.addToQueue(q[1], id: \.id, queue: &q, index: &i, queued: []))
        XCTAssertEqual(names(q), ["a", "b"])
    }

    func testShuffleKeepsCurrentFirstThenPinned() {
        var q = make("a", "b", "c", "x", "d", "e"); var i = 2
        let pinned: Set<UUID> = [q[3].id]
        var rng = SeededGenerator(state: 42)
        PlayQueueOps.shuffle(id: \.id, pinned: pinned, queue: &q, index: &i, using: &rng)
        XCTAssertEqual(i, 0)
        XCTAssertEqual(Array(names(q).prefix(2)), ["c", "x"])
        XCTAssertEqual(Set(names(q)), ["a", "b", "c", "x", "d", "e"])
        XCTAssertEqual(q.count, 6)
    }

    func testUnshuffleRestoresOriginalOrderAroundCurrent() {
        let original = make("a", "b", "c", "d", "e")
        var q = original; var i = 2
        var rng = SeededGenerator(state: 7)
        PlayQueueOps.shuffle(id: \.id, pinned: [], queue: &q, index: &i, using: &rng)
        PlayQueueOps.unshuffle(id: \.id, pinned: [], originalOrder: original.map(\.id), queue: &q, index: &i)
        XCTAssertEqual(names(q), ["a", "b", "c", "d", "e"]); XCTAssertEqual(i, 2)
    }

    func testUnshuffleKeepsPinnedAfterCurrentAndUnknownLast() {
        let original = make("a", "b", "c", "d")
        let x = Item(name: "x"), y = Item(name: "y")
        var q = [original[2], x, original[3], y, original[0], original[1]]; var i = 0
        PlayQueueOps.unshuffle(id: \.id, pinned: [x.id], originalOrder: original.map(\.id), queue: &q, index: &i)
        XCTAssertEqual(names(q), ["a", "b", "c", "x", "d", "y"]); XCTAssertEqual(i, 2)
    }

    func testUnshuffleWithUnknownCurrentContinuesContext() {
        let original = make("a", "b", "c", "d")
        let x = Item(name: "x")
        var q = [original[0], original[2], x, original[3], original[1]]; var i = 2
        PlayQueueOps.unshuffle(id: \.id, pinned: [], originalOrder: original.map(\.id), queue: &q, index: &i)
        XCTAssertEqual(names(q), ["a", "b", "c", "x", "d"]); XCTAssertEqual(i, 3)
    }

    func testUnshuffleWithUnknownCurrentAndNoPlayedContextStartsAtFront() {
        let original = make("a", "b", "c")
        let x = Item(name: "x"), y = Item(name: "y")
        var q = [x, y, original[1], original[0], original[2]]; var i = 0
        PlayQueueOps.unshuffle(id: \.id, pinned: [y.id], originalOrder: original.map(\.id), queue: &q, index: &i)
        XCTAssertEqual(names(q), ["x", "y", "a", "b", "c"]); XCTAssertEqual(i, 0)
    }

    func testUnshuffleDropsAlreadyPlayedUnknownEntries() {
        let original = make("a", "b", "c")
        let x = Item(name: "x")
        var q = [original[1], x, original[0], original[2]]; var i = 2
        PlayQueueOps.unshuffle(id: \.id, pinned: [], originalOrder: original.map(\.id), queue: &q, index: &i)
        XCTAssertEqual(names(q), ["a", "b", "c"]); XCTAssertEqual(i, 0)
    }

    func testPlayNextInsertsAfterCurrentAndMovesExisting() {
        var q = make("a", "b", "c", "d"); var i = 1
        PlayQueueOps.playNext(q[3], id: \.id, queue: &q, index: &i)
        XCTAssertEqual(names(q), ["a", "b", "d", "c"]); XCTAssertEqual(i, 1)
        PlayQueueOps.playNext(q[0], id: \.id, queue: &q, index: &i)
        XCTAssertEqual(names(q), ["b", "a", "d", "c"]); XCTAssertEqual(i, 0)
        XCTAssertEqual(q[i].name, "b")
    }

    func testPlayNextCurrentIsNoOp() {
        var q = make("a", "b"); var i = 0
        XCTAssertFalse(PlayQueueOps.playNext(q[0], id: \.id, queue: &q, index: &i))
        XCTAssertEqual(names(q), ["a", "b"])
    }

    func testPruneKeepsCurrentIndex() {
        var q = make("a", "b", "c", "d"); var i = 2
        let removed: Set<UUID> = [q[0].id, q[3].id]
        PlayQueueOps.prune(id: \.id, removing: removed, queue: &q, index: &i)
        XCTAssertEqual(names(q), ["b", "c"]); XCTAssertEqual(i, 1)
    }

    func testPruneCurrentEmptiesQueue() {
        var q = make("a", "b"); var i = 0
        PlayQueueOps.prune(id: \.id, removing: [q[0].id], queue: &q, index: &i)
        XCTAssertTrue(q.isEmpty); XCTAssertEqual(i, 0)
    }

    private func playOrder(_ q: [Item], from start: Int) -> [String] {
        Array(q[(start + 1)...]).map(\.name)
    }

    func testContextKeepsListWhenItHoldsTheItem() {
        let library = make("a", "b", "c")
        XCTAssertEqual(names(PlayQueueOps.context(for: library[1], id: \.id, in: library)), ["a", "b", "c"])
    }

    func testContextReplacesSiblingInPlace() {
        let library = make("a", "b2", "c")
        let older = Item(name: "b1")
        let context = PlayQueueOps.context(for: older, id: \.id, in: library) { $0.name == "b2" }
        XCTAssertEqual(names(context), ["a", "b1", "c"])
    }

    func testContextPutsItemOutsideListFirst() {
        let library = make("a", "b")
        let outside = Item(name: "x")
        XCTAssertEqual(names(PlayQueueOps.context(for: outside, id: \.id, in: library)), ["x", "a", "b"])
    }

    func testSingleTrackStartWithTwoQueuedPlaysQueuedThenContinuesContext() {
        let library = make("a", "b", "c", "d")
        let started = Item(name: "s")
        var q = PlayQueueOps.context(for: started, id: \.id, in: library)
        var i = q.firstIndex(of: started)!
        var queued: Set<UUID> = []
        for item in [library[2], Item(name: "x")] {
            PlayQueueOps.addToQueue(item, id: \.id, queue: &q, index: &i, queued: queued)
            queued.insert(item.id)
        }
        XCTAssertEqual(q[i].name, "s")
        XCTAssertEqual(playOrder(q, from: i), ["c", "x", "a", "b", "d"])
        XCTAssertEqual(Set(q.map(\.id)).count, q.count)
    }

    func testStartMidListWithTwoQueuedFromEarlierRowsContinuesAfterStart() {
        var q = make("q1", "q2", "s", "d", "e")
        var i = 2
        let q1 = q[0], q2 = q[1]
        var queued: Set<UUID> = []
        for item in [q1, q2] {
            PlayQueueOps.addToQueue(item, id: \.id, queue: &q, index: &i, queued: queued)
            queued.insert(item.id)
        }
        XCTAssertEqual(q[i].name, "s")
        XCTAssertEqual(playOrder(q, from: i), ["q1", "q2", "d", "e"])
    }
}
