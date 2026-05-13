import Foundation

@objc public protocol ISSXPCServiceProtocol {
    func switchSpace(_ direction: Int, reply: @escaping (Bool, String?) -> Void)
    func ping(reply: @escaping (String) -> Void)
    func daemonRuntimeInfo(reply: @escaping (String, String, Bool) -> Void)
    func daemonAccessibilityPermissionStatus(reply: @escaping (Bool) -> Void)
    func requestDaemonAccessibilityPermission(reply: @escaping (Bool) -> Void)
}
