import ApplicationServices
import Foundation

enum InputPermissionManager {
    static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
