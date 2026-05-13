import Foundation

enum CLIInstaller {
    static func isInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: ISSConstants.cliInstallPath)
    }

    static func install() async throws {
        guard let source = resolveCLISourceURL() else {
            throw NSError(
                domain: "iss.cli",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to find CLI binary. Build ISSCLI target first."]
            )
        }

        try await runPrivileged(tool: source.path, args: ["install"])
    }

    static func uninstall() async throws {
        // Prefer the bundled binary so we work even if /usr/local/bin/issctl
        // was already removed manually.
        let tool = resolveCLISourceURL()?.path ?? ISSConstants.cliInstallPath
        try await runPrivileged(tool: tool, args: ["uninstall"])
    }

    private static func resolveCLISourceURL() -> URL? {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL

        let candidates: [URL] = [
            bundle.appendingPathComponent("Contents/Library/Helpers/\(ISSConstants.cliExecutableName)"),
            bundle.appendingPathComponent("Contents/Resources/\(ISSConstants.cliExecutableName)"),
            bundle.deletingLastPathComponent().appendingPathComponent(ISSConstants.cliExecutableName),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(ISSConstants.cliExecutableName)
        ]

        return candidates.first(where: { fm.isExecutableFile(atPath: $0.path) })
    }

    private static func runPrivileged(tool: String, args: [String]) async throws {
        let status: Int32 = await withCheckedContinuation { continuation in
            var cArgs: [UnsafePointer<CChar>?] = args.map { NSString(string: $0).utf8String }
            cArgs.append(nil)

            cArgs.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    continuation.resume(returning: Int32(errAuthorizationDenied))
                    return
                }
                ISSRunPrivilegedCommand(tool, base) { status in
                    continuation.resume(returning: status)
                }
            }
        }

        guard status == errAuthorizationSuccess else {
            throw NSError(
                domain: "iss.cli",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Failed running privileged command: \(tool). OSStatus=\(status)"]
            )
        }
    }
}
