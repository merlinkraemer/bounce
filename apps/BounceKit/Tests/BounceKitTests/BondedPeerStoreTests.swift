import XCTest
@testable import BounceKit

private final class FakeKeychain: KeychainStoring {
    var stored: Data?
    var loadResult: KeychainHelper.LoadResult?
    var saveStatus: OSStatus?
    var saveCount = 0

    func save(_ data: Data, service: String, account: String) -> OSStatus? {
        saveCount += 1
        if let saveStatus { return saveStatus }
        stored = data
        return nil
    }

    func load(service: String, account: String) -> KeychainHelper.LoadResult {
        if let loadResult { return loadResult }
        return stored.map { .success($0) } ?? .notFound
    }
}

@MainActor
final class BondedPeerStoreTests: XCTestCase {
    private func peer(_ name: String) -> BondedPeer {
        BondedPeer(id: UUID(), name: name, sharedKey: Data([1, 2, 3]))
    }

    private func store(_ kc: FakeKeychain) -> BondedPeerStore {
        BondedPeerStore(service: "s", account: "a", keychain: kc)
    }

    func testFailedReadNeverOverwritesStoredBonds() throws {
        let kc = FakeKeychain()
        kc.stored = try JSONEncoder().encode([peer("Real")])
        kc.loadResult = .failure(errSecInteractionNotAllowed)
        let s = store(kc)
        XCTAssertTrue(s.peers.isEmpty)
        s.bond(peer("New"))
        XCTAssertEqual(kc.saveCount, 0)
        XCTAssertEqual(try JSONDecoder().decode([BondedPeer].self, from: kc.stored!).first?.name, "Real")
    }

    func testRecoversAndMergesOnceReadWorks() throws {
        let kc = FakeKeychain()
        kc.stored = try JSONEncoder().encode([peer("Real")])
        kc.loadResult = .failure(errSecAuthFailed)
        let s = store(kc)
        s.bond(peer("New"))
        kc.loadResult = nil
        s.bond(peer("Newer"))
        let saved = try JSONDecoder().decode([BondedPeer].self, from: kc.stored!)
        XCTAssertEqual(Set(saved.map(\.name)), ["Real", "New", "Newer"])
    }

    func testUnreadableBondsAreReportedUntilAReadWorks() throws {
        let kc = FakeKeychain()
        let real = peer("Real")
        kc.stored = try JSONEncoder().encode([real])
        kc.loadResult = .failure(errSecInteractionNotAllowed)
        let s = store(kc)
        let start = Date()
        XCTAssertTrue(s.storedBondsUnreadable(now: start))
        kc.loadResult = nil
        XCTAssertTrue(s.storedBondsUnreadable(now: start.addingTimeInterval(5)))
        XCTAssertFalse(s.storedBondsUnreadable(now: start.addingTimeInterval(31)))
        XCTAssertNotNil(s.authorize(id: real.id, sharedKey: real.sharedKey))
    }

    func testReadableBondsAreNeverReportedUnreadable() {
        let kc = FakeKeychain()
        XCTAssertFalse(store(kc).storedBondsUnreadable())
    }

    func testCorruptBlobIsNotOverwritten() {
        let kc = FakeKeychain()
        kc.stored = Data("garbage".utf8)
        let s = store(kc)
        s.bond(peer("New"))
        XCTAssertEqual(kc.saveCount, 0)
        XCTAssertEqual(kc.stored, Data("garbage".utf8))
    }

    func testFailedWriteIsSurfacedAndNotTreatedAsFlushed() {
        let kc = FakeKeychain()
        kc.saveStatus = errSecInteractionNotAllowed
        let s = store(kc)
        s.bond(peer("A"))
        XCTAssertEqual(s.lastPersistFailure, errSecInteractionNotAllowed)
        kc.saveStatus = nil
        s.bond(peer("B"))
        XCTAssertNil(s.lastPersistFailure)
        XCTAssertEqual(kc.saveCount, 2)
    }

    func testBodyCaps() {
        XCTAssertEqual(SyncBodyLimit.pair, 64 * 1024)
        XCTAssertLessThan(SyncBodyLimit.pair, SyncBodyLimit.playlistArtwork)
        XCTAssertLessThan(SyncBodyLimit.playlistArtwork, SyncBodyLimit.iosManifest)
    }
}
