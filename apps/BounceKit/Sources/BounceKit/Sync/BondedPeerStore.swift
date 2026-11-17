import Foundation

/// A peer (Mac or iOS) that has been explicitly approved by the user.
///
/// Bonding swaps a randomly generated `sharedKey` between the two devices
/// on first pair. That key is sent on every subsequent request as
/// `X-Bounce-Pair-Key` so an unbonded device on the same network can't fetch
/// data even if it discovers the Bonjour service.
public struct BondedPeer: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var sharedKey: Data
    public var bondedAt: Date
    public var lastSeenAt: Date
    public var consecutiveAuthFailures: Int = 0
    public var lastAuthFailureAt: Date? = nil

    public init(
        id: UUID,
        name: String,
        sharedKey: Data,
        bondedAt: Date = .now,
        lastSeenAt: Date = .now,
        consecutiveAuthFailures: Int = 0,
        lastAuthFailureAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.sharedKey = sharedKey
        self.bondedAt = bondedAt
        self.lastSeenAt = lastSeenAt
        self.consecutiveAuthFailures = consecutiveAuthFailures
        self.lastAuthFailureAt = lastAuthFailureAt
    }

    public var sharedKeyHex: String {
        sharedKey.map { String(format: "%02x", $0) }.joined()
    }
}

/// Keychain-backed list of bonded peers for one role on this device.
///
/// Storage layout: a single JSON-encoded `[BondedPeer]` blob under a
/// keychain entry keyed by `(service, account)`.
@Observable
@MainActor
public final class BondedPeerStore {

    private let service: String
    private let account: String

    public private(set) var peers: [BondedPeer]

    private let keychain: KeychainStoring

    /// Set when the stored bond list could not be read (access denied,
    /// corrupt blob). The stored value may still be intact, so the store
    /// refuses to overwrite it until a read succeeds.
    private var loadFailed = false

    /// Status of the last failed Keychain write, nil after a successful one.
    public private(set) var lastPersistFailure: OSStatus?

    /// Last time peers were written to the Keychain. `touch` updates
    /// `lastSeenAt` in memory on every authorised request; Keychain
    /// SecItemUpdate is throttled to at most once per this interval
    /// unless bond/forget/auth-change forces an immediate flush.
    private var lastKeychainFlushAt: Date = .distantPast
    private let keychainFlushInterval: TimeInterval = 180

    private var lastUnreadableRetryAt: Date = .distantPast
    private let unreadableRetryInterval: TimeInterval = 30

    public convenience init(role: SyncRole) {
        self.init(
            service: BounceConstants.keychainService,
            account: "bondedPeers." + (role == .sender ? "sender" : "receiver"),
            keychain: SystemKeychain()
        )
    }

    init(service: String, account: String, keychain: KeychainStoring) {
        self.service = service
        self.account = account
        self.keychain = keychain
        let loaded = Self.load(keychain: keychain, service: service, account: account)
        self.peers = loaded.peers
        self.loadFailed = loaded.failed
        if !peers.isEmpty {
            lastKeychainFlushAt = .now
        }
    }

    public var isEmpty: Bool { peers.isEmpty }

    public func peer(id: UUID) -> BondedPeer? {
        peers.first { $0.id == id }
    }

    public func contains(id: UUID) -> Bool {
        peers.contains { $0.id == id }
    }

    /// Returns the matching peer if both id and shared key match. Used for
    /// authorising incoming requests on the sender.
    public func authorize(id: UUID, sharedKey: Data) -> BondedPeer? {
        guard let peer = peer(id: id) else { return nil }
        return peer.sharedKey == sharedKey ? peer : nil
    }

    @discardableResult
    public func bond(_ peer: BondedPeer) -> BondedPeer {
        if let index = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
        persist(force: true)
        return peer
    }

    public func forget(id: UUID) {
        peers.removeAll { $0.id == id }
        persist(force: true)
    }

    public func touch(id: UUID, name: String? = nil) {
        guard let index = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[index].lastSeenAt = .now
        if let name, !name.isEmpty {
            peers[index].name = name
        }
        // In-memory only unless the throttled flush window has elapsed.
        persist(force: false)
    }

    public func recordAuthFailure(id: UUID) {
        guard let index = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[index].consecutiveAuthFailures += 1
        peers[index].lastAuthFailureAt = .now
        persist(force: true)
    }

    public func resetAuthFailures(id: UUID) {
        guard let index = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[index].consecutiveAuthFailures = 0
        peers[index].lastAuthFailureAt = nil
        persist(force: true)
    }

    /// True while the stored bond list cannot be read (e.g. Keychain locked at
    /// launch). Retries the read at most every 30 s; callers must not treat an
    /// unknown peer as forgotten while this is true.
    public func storedBondsUnreadable(now: Date = .now) -> Bool {
        guard loadFailed else { return false }
        guard now.timeIntervalSince(lastUnreadableRetryAt) >= unreadableRetryInterval else { return true }
        lastUnreadableRetryAt = now
        let loaded = Self.load(keychain: keychain, service: service, account: account)
        guard !loaded.failed else { return true }
        adoptStoredPeers(loaded.peers)
        return false
    }

    private func adoptStoredPeers(_ stored: [BondedPeer]) {
        loadFailed = false
        var merged = stored.filter { stored in !peers.contains { $0.id == stored.id } }
        merged.append(contentsOf: peers)
        peers = merged
    }

    public func reload() {
        let loaded = Self.load(keychain: keychain, service: service, account: account)
        loadFailed = loaded.failed
        if !loaded.failed { peers = loaded.peers }
    }

    private func persist(force: Bool) {
        let now = Date()
        if !force, now.timeIntervalSince(lastKeychainFlushAt) < keychainFlushInterval {
            return
        }
        if loadFailed {
            // Retry the read; if it works now, keep this session's changes on
            // top of what is stored. Otherwise never overwrite the stored list.
            let loaded = Self.load(keychain: keychain, service: service, account: account)
            guard !loaded.failed else {
                SyncLog.transport.error("bond store not saved: stored bonds are unreadable; keeping them untouched")
                return
            }
            adoptStoredPeers(loaded.peers)
        }
        do {
            let data = try JSONEncoder().encode(peers)
            if let status = keychain.save(data, service: service, account: account) {
                lastPersistFailure = status
                SyncLog.transport.error("bond store Keychain write failed (status \(status, privacy: .public)); bonds are in memory only")
                return
            }
            lastPersistFailure = nil
            lastKeychainFlushAt = now
        } catch {
            // Encoding a [BondedPeer] should never fail in practice; we still
            // continue so an in-memory bond at least works for this session.
            assertionFailure("BondedPeerStore: failed to encode peers: \(error)")
        }
    }

    private static func load(keychain: KeychainStoring, service: String, account: String) -> (peers: [BondedPeer], failed: Bool) {
        switch keychain.load(service: service, account: account) {
        case .notFound:
            return ([], false)
        case .failure(let status):
            SyncLog.transport.error("bond store unreadable (Keychain status \(status, privacy: .public))")
            return ([], true)
        case .success(let data):
            guard let decoded = try? JSONDecoder().decode([BondedPeer].self, from: data) else {
                SyncLog.transport.error("bond store blob failed to decode; leaving it untouched")
                return ([], true)
            }
            return (decoded, false)
        }
    }
}

/// Keychain access seam so bond-store failure handling is testable.
protocol KeychainStoring {
    func save(_ data: Data, service: String, account: String) -> OSStatus?
    func load(service: String, account: String) -> KeychainHelper.LoadResult
}

struct SystemKeychain: KeychainStoring {
    func save(_ data: Data, service: String, account: String) -> OSStatus? {
        KeychainHelper.save(data, service: service, account: account)
    }
    func load(service: String, account: String) -> KeychainHelper.LoadResult {
        KeychainHelper.load(service: service, account: account)
    }
}

/// Generate a fresh random shared key for a brand-new bond.
public func makeSharedPairingKey() -> Data {
    var key = Data(count: 32)
    _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    return key
}
