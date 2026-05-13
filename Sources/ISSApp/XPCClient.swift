import Foundation

struct DaemonRuntimeInfo {
    let binaryHash: String
    let executablePath: String
    let accessibilityGranted: Bool
}

enum XPCClient {
    static func switchSpace(direction: SpaceDirection, timeout: TimeInterval = 2.0) async throws {
        let connection = NSXPCConnection(machServiceName: ISSConstants.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ISSXPCServiceProtocol.self)
        connection.resume()

        defer {
            connection.invalidate()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let remote = connection.remoteObjectProxyWithErrorHandler { error in
                        continuation.resume(throwing: error)
                    } as? ISSXPCServiceProtocol

                    remote?.switchSpace(direction.rawValue) { ok, message in
                        if ok {
                            continuation.resume(returning: ())
                        } else {
                            continuation.resume(throwing: NSError(
                                domain: "iss.xpc",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: message ?? "Unknown daemon error"]
                            ))
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "iss.xpc", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out connecting to daemon"])
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    static func daemonRuntimeInfo(timeout: TimeInterval = 2.0) async throws -> DaemonRuntimeInfo {
        let connection = NSXPCConnection(machServiceName: ISSConstants.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ISSXPCServiceProtocol.self)
        connection.resume()

        defer {
            connection.invalidate()
        }

        return try await withThrowingTaskGroup(of: DaemonRuntimeInfo.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let remote = connection.remoteObjectProxyWithErrorHandler { error in
                        continuation.resume(throwing: error)
                    } as? ISSXPCServiceProtocol

                    remote?.daemonRuntimeInfo { binaryHash, executablePath, granted in
                        continuation.resume(returning: DaemonRuntimeInfo(
                            binaryHash: binaryHash,
                            executablePath: executablePath,
                            accessibilityGranted: granted
                        ))
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "iss.xpc", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out connecting to daemon"])
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func daemonAccessibilityPermissionStatus(timeout: TimeInterval = 2.0) async throws -> Bool {
        let connection = NSXPCConnection(machServiceName: ISSConstants.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ISSXPCServiceProtocol.self)
        connection.resume()

        defer {
            connection.invalidate()
        }

        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let remote = connection.remoteObjectProxyWithErrorHandler { error in
                        continuation.resume(throwing: error)
                    } as? ISSXPCServiceProtocol

                    remote?.daemonAccessibilityPermissionStatus { granted in
                        continuation.resume(returning: granted)
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "iss.xpc", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out connecting to daemon"])
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func requestDaemonAccessibilityPermission(timeout: TimeInterval = 2.0) async throws -> Bool {
        let connection = NSXPCConnection(machServiceName: ISSConstants.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ISSXPCServiceProtocol.self)
        connection.resume()

        defer {
            connection.invalidate()
        }

        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let remote = connection.remoteObjectProxyWithErrorHandler { error in
                        continuation.resume(throwing: error)
                    } as? ISSXPCServiceProtocol

                    remote?.requestDaemonAccessibilityPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "iss.xpc", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out connecting to daemon"])
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
