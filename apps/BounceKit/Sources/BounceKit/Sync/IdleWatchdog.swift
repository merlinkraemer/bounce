import Foundation

final class IdleWatchdog: @unchecked Sendable {
    private let idleTimeout: TimeInterval
    private let lock = NSLock()
    private var lastActivity: Date
    private var fired = false

    init(idleTimeout: TimeInterval, now: Date = Date()) {
        self.idleTimeout = idleTimeout
        self.lastActivity = now
    }

    func touch(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        lastActivity = now
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    func expireIfIdle(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if now.timeIntervalSince(lastActivity) >= idleTimeout {
            fired = true
        }
        return fired
    }

    func start(onExpire: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let interval = min(1, idleTimeout)
        return Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if !Task.isCancelled, expireIfIdle() {
                    onExpire()
                    return
                }
            }
        }
    }
}
