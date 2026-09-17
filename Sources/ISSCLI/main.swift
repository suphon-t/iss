import Foundation

private enum CLIError: Error {
    case badUsage
    case failure(String)
}

private func printUsage() {
    print("Usage: issctl <left|right|install|uninstall>")
}

private func parseDirection(_ value: String) throws -> SpaceDirection {
    switch value.lowercased() {
    case "left", "prev", "previous":
        return .left
    case "right", "next":
        return .right
    default:
        throw CLIError.badUsage
    }
}

// Copy this binary to ISSConstants.cliInstallPath. Requires root, so the
// caller (typically the app via Authorization Services) is responsible for
// privilege escalation.
private func installSelf() throws {
    let fm = FileManager.default
    guard let source = Bundle.main.executablePath else {
        throw CLIError.failure("Could not resolve own executable path")
    }
    let destDir = ISSConstants.cliInstallDirectory
    let destPath = ISSConstants.cliInstallPath

    try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

    if fm.fileExists(atPath: destPath) {
        try fm.removeItem(atPath: destPath)
    }
    try fm.copyItem(atPath: source, toPath: destPath)

    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)

    guard fm.isExecutableFile(atPath: destPath) else {
        throw CLIError.failure("Install completed but executable was not found at \(destPath)")
    }
}

private func uninstallSelf() throws {
    let fm = FileManager.default
    let destPath = ISSConstants.cliInstallPath
    if fm.fileExists(atPath: destPath) {
        try fm.removeItem(atPath: destPath)
    }
}

// Ask the running ISSApp to switch spaces via a distributed notification and
// wait for its reply. Requires ISSApp to be running.
private func switchSpace(direction: SpaceDirection, timeout: TimeInterval = 2.0) throws {
    let center = DistributedNotificationCenter.default()
    let requestID = UUID().uuidString
    var replyOK = false
    var replyMessage = ""
    var gotReply = false

    let observer = center.addObserver(
        forName: Notification.Name(ISSConstants.switchReplyName),
        object: nil,
        queue: .main
    ) { note in
        guard let payload = note.object as? String else { return }
        let parts = payload.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, String(parts[0]) == requestID else { return }
        replyOK = (parts[1] == "ok")
        replyMessage = parts.count > 2 ? String(parts[2]) : ""
        gotReply = true
    }
    defer { center.removeObserver(observer) }

    let dirString = direction == .left ? "left" : "right"
    center.postNotificationName(
        Notification.Name(ISSConstants.switchRequestName),
        object: "\(requestID)|\(dirString)",
        userInfo: nil,
        deliverImmediately: true
    )

    // Distributed notifications arrive on the run loop, so spin it until the
    // reply lands or the deadline passes.
    let deadline = Date().addingTimeInterval(timeout)
    while !gotReply && Date() < deadline {
        RunLoop.current.run(mode: .default, before: deadline)
    }

    if !gotReply {
        throw CLIError.failure("ISSApp did not respond. Make sure ISSApp is running.")
    }
    if !replyOK {
        throw CLIError.failure(replyMessage.isEmpty ? "Switch failed." : replyMessage)
    }
}

do {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        throw CLIError.badUsage
    }

    switch args[1].lowercased() {
    case "install":
        try installSelf()
        print("ok")
    case "uninstall":
        try uninstallSelf()
        print("ok")
    default:
        let direction = try parseDirection(args[1])
        try switchSpace(direction: direction)
        print("ok")
    }
} catch CLIError.badUsage {
    printUsage()
    Foundation.exit(64)
} catch CLIError.failure(let msg) {
    fputs("error: \(msg)\n", stderr)
    Foundation.exit(1)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
}
