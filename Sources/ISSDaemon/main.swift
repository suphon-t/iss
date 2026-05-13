import Foundation
import ApplicationServices
import CryptoKit
import os

let log = Logger(subsystem: "com.instant-swipe.issd", category: "daemon")

private func sha256Hex(forFileAtPath path: String) -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        return ""
    }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

// Hash the binary once at startup. Re-reading the executable file later can
// return the hash of an updated on-disk binary that does not match the code
// actually running in this process.
private let runningBinaryPath: String = Bundle.main.executablePath ?? ""
private let runningBinaryHash: String = sha256Hex(forFileAtPath: runningBinaryPath)

final class DaemonXPCService: NSObject, ISSXPCServiceProtocol {
    let switcher = SpaceSwitcher()

    func switchSpace(_ direction: Int, reply: @escaping (Bool, String?) -> Void) {
        guard let resolvedDirection = SpaceDirection(rawValue: direction) else {
            reply(false, "Invalid direction: use -1 for left or 1 for right")
            return
        }

        log.info("switchSpace(\(direction)) called")
        let ok = switcher.switchSpace(direction: resolvedDirection)
        log.info("switchSpace returned \(ok)")
        if ok {
            reply(true, nil)
        } else {
            if !AXIsProcessTrusted() {
                reply(false, "Switch failed. Ensure Accessibility permission is granted.")
            } else if !switcher.canSwitch(direction: resolvedDirection) {
                let edge = resolvedDirection == .left ? "leftmost" : "rightmost"
                reply(false, "Already at the \(edge) space.")
            } else {
                reply(false, "Switch failed.")
            }
        }
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("issd alive")
    }

    func daemonRuntimeInfo(reply: @escaping (String, String, Bool) -> Void) {
        log.info("daemonRuntimeInfo: path=\(runningBinaryPath, privacy: .public) hash=\(runningBinaryHash, privacy: .public)")
        reply(runningBinaryHash, runningBinaryPath, AXIsProcessTrusted())
    }

    func daemonAccessibilityPermissionStatus(reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    func requestDaemonAccessibilityPermission(reply: @escaping (Bool) -> Void) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        reply(AXIsProcessTrustedWithOptions(opts))
    }
}

final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = DaemonXPCService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ISSXPCServiceProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: ISSConstants.machServiceName)
let delegate = DaemonListenerDelegate()
listener.delegate = delegate
listener.resume()

if !delegate.service.switcher.startMonitoring() {
    fputs("issd: accessibility not yet granted — prompting user\n", stderr)
    // Prompt the user to add ISSDaemon to Accessibility in Privacy & Security.
    // The dialog appears even from a background agent. Run off the main
    // thread so the XPC listener can service requests while the prompt is up.
    // DispatchQueue.global(qos: .userInitiated).async {
    //     let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    //     AXIsProcessTrustedWithOptions(opts)
    // }

    // Keep retrying until the user approves or revokes.
    var monitorRetry: Timer?
    monitorRetry = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
        if delegate.service.switcher.startMonitoring() {
            fputs("issd: gesture monitor started\n", stderr)
            timer.invalidate()
        }
    }
    RunLoop.main.add(monitorRetry!, forMode: .common)
} else {
    fputs("issd: gesture monitor started\n", stderr)
}

RunLoop.main.run()
