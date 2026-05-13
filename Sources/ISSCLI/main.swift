import Foundation

private enum CLIError: Error {
    case badUsage
    case xpc(String)
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
        throw CLIError.xpc("Could not resolve own executable path")
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
        throw CLIError.xpc("Install completed but executable was not found at \(destPath)")
    }
}

private func uninstallSelf() throws {
    let fm = FileManager.default
    let destPath = ISSConstants.cliInstallPath
    if fm.fileExists(atPath: destPath) {
        try fm.removeItem(atPath: destPath)
    }
}

private func switchSpace(direction: SpaceDirection, timeout: TimeInterval = 2.0) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var resultError: Error?

    let connection = NSXPCConnection(machServiceName: ISSConstants.machServiceName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: ISSXPCServiceProtocol.self)
    connection.invalidationHandler = { semaphore.signal() }
    connection.interruptionHandler = { semaphore.signal() }
    connection.resume()

    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        resultError = error
        semaphore.signal()
    } as? ISSXPCServiceProtocol

    proxy?.switchSpace(direction.rawValue) { ok, message in
        if !ok {
            resultError = CLIError.xpc(message ?? "Daemon rejected command")
        }
        semaphore.signal()
    }

    let waitResult = semaphore.wait(timeout: .now() + timeout)
    connection.invalidate()

    if waitResult == .timedOut {
        throw CLIError.xpc("Timed out waiting for daemon")
    }

    if let resultError {
        throw resultError
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
} catch CLIError.xpc(let msg) {
    fputs("error: \(msg)\n", stderr)
    Foundation.exit(1)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
}
