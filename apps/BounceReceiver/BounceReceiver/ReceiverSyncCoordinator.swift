import Foundation
import BounceKit

actor ReceiverSyncCoordinator {
    enum Trigger: String, Sendable {
        case connected
        case manual
        case periodic
    }

    struct SyncLease: Sendable {
        let id: Int
        let senderID: UUID?
        let trigger: Trigger
    }

    struct ConnectionDirective: Sendable {
        let shouldStartImmediateSync: Bool
        let shouldCancelRunningSync: Bool
        let scheduleToken: UUID?
    }

    private var currentState: SyncConnectionState = .disconnected
    private var currentSenderID: UUID? = nil
    private var scheduleToken = UUID()
    private var nextLeaseID: Int = 0
    private var activeLeaseID: Int? = nil

    func handleConnectionStateChange(_ state: SyncConnectionState, senderID: UUID?) -> ConnectionDirective {
        let previousState = currentState
        let previousSenderID = currentSenderID

        currentState = state

        switch state {
        case .connected:
            currentSenderID = senderID
            let senderChanged = previousSenderID != senderID
            let newlyConnected = previousState != .connected
            if senderChanged || newlyConnected {
                scheduleToken = UUID()
                activeLeaseID = nil
            }
            return ConnectionDirective(
                shouldStartImmediateSync: senderChanged || newlyConnected,
                shouldCancelRunningSync: senderChanged || previousState != .connected,
                scheduleToken: scheduleToken
            )
        default:
            currentSenderID = nil
            scheduleToken = UUID()
            let hadActiveSync = activeLeaseID != nil
            activeLeaseID = nil
            return ConnectionDirective(
                shouldStartImmediateSync: false,
                shouldCancelRunningSync: hadActiveSync,
                scheduleToken: nil
            )
        }
    }

    func beginSync(trigger: Trigger, senderID: UUID?) -> SyncLease? {
        guard currentState == .connected else { return nil }
        if let currentSenderID, let senderID, currentSenderID != senderID {
            return nil
        }
        guard activeLeaseID == nil else { return nil }

        nextLeaseID += 1
        let lease = SyncLease(id: nextLeaseID, senderID: currentSenderID, trigger: trigger)
        activeLeaseID = lease.id
        return lease
    }

    func finishSync(_ lease: SyncLease) {
        guard activeLeaseID == lease.id else { return }
        activeLeaseID = nil
    }
}
