import Foundation
import ApplicationServices
import os

private let log = Logger(subsystem: "com.instant-swipe.iss", category: "command")

/// Receives switch commands from the issctl CLI over distributed notifications
/// and posts back the outcome. No launchd registration required — the app only
/// needs to be running.
final class CommandReceiver {
    private let switcher: SpaceSwitcher

    init(switcher: SpaceSwitcher) {
        self.switcher = switcher
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(ISSConstants.switchRequestName),
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handle(note)
        }
        log.info("CommandReceiver listening for \(ISSConstants.switchRequestName, privacy: .public)")
    }

    /// Request payload: "<requestID>|<left|right>".
    private func handle(_ note: Notification) {
        guard let payload = note.object as? String else { return }
        let parts = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }

        let requestID = String(parts[0])
        let direction: SpaceDirection
        switch parts[1] {
        case "left": direction = .left
        case "right": direction = .right
        default: return
        }

        let (ok, message) = perform(direction)
        reply(requestID: requestID, ok: ok, message: message)
    }

    private func perform(_ direction: SpaceDirection) -> (Bool, String) {
        if !AXIsProcessTrusted() {
            return (false, "Accessibility permission not granted to ISSApp.")
        }
        if switcher.switchSpace(direction: direction) {
            return (true, "")
        }
        if !switcher.canSwitch(direction: direction) {
            let edge = direction == .left ? "leftmost" : "rightmost"
            return (false, "Already at the \(edge) space.")
        }
        return (false, "Switch failed.")
    }

    /// Reply payload: "<requestID>|<ok|err>|<message>".
    private func reply(requestID: String, ok: Bool, message: String) {
        let status = ok ? "ok" : "err"
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(ISSConstants.switchReplyName),
            object: "\(requestID)|\(status)|\(message)",
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
