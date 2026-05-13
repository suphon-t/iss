import Foundation
import ServiceManagement
import CryptoKit

enum DaemonServiceManager {
    private static func launchdServiceTarget() -> String {
        "gui/\(getuid())/\(ISSConstants.machServiceName)"
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw error
        }

        if process.terminationStatus != 0 {
            throw NSError(
                domain: "iss.launchctl",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "launchctl \(arguments.joined(separator: " ")) failed with status \(process.terminationStatus)"]
            )
        }
    }

    static func installOrUpdateDaemon() throws {
        let service = SMAppService.agent(plistName: ISSConstants.daemonPlistName)
        let target = launchdServiceTarget()

        // Force old job teardown first so launchd cannot keep serving a stale binary.
        try? runLaunchctl(["bootout", target])
        try? service.unregister()
        try service.register()

        // Force immediate restart so the new registration is what answers XPC.
//        try? runLaunchctl(["kickstart", "-k", target])
    }

    static func registerDaemon() throws {
        let service = SMAppService.agent(plistName: ISSConstants.daemonPlistName)
        try service.register()
    }

    static func unregisterDaemon() throws {
        let service = SMAppService.agent(plistName: ISSConstants.daemonPlistName)
        try service.unregister()
    }

    static func statusDescription() -> String {
        let service = SMAppService.agent(plistName: ISSConstants.daemonPlistName)
        switch service.status {
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requires approval in Login Items"
        case .notRegistered:
            return "not registered"
        case .notFound:
            return "daemon plist missing"
        @unknown default:
            return "unknown"
        }
    }

    static func expectedDaemonExecutablePath() -> String {
        Bundle.main.bundlePath + "/Contents/Resources/ISSDaemon"
    }

    static func expectedDaemonExecutableHash() -> String {
        let path = expectedDaemonExecutablePath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ""
        }

        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
