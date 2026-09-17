import Foundation
import ApplicationServices
import SwiftUI
import os

private let log = Logger(subsystem: "com.instant-swipe.iss", category: "app")

@MainActor
final class AppModel: ObservableObject {
    let switcher = SpaceSwitcher()
    private let commands: CommandReceiver

    @Published var accessibilityGranted: Bool = AXIsProcessTrusted()
    @Published var launchAtLoginEnabled: Bool = LoginItemManager.isEnabled
    @Published var cliInstalled: Bool = CLIInstaller.isInstalled()

    @Published var showMenuBarItem: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarItem, forKey: ISSDefaults.showMenuBarItem)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [ISSDefaults.showMenuBarItem: true])
        showMenuBarItem = defaults.bool(forKey: ISSDefaults.showMenuBarItem)

        commands = CommandReceiver(switcher: switcher)
        _ = switcher.startMonitoring()
        log.info("AppModel initialized; monitoring=\(self.switcher.startMonitoring())")
    }

    func switchSpace(_ direction: SpaceDirection) -> Bool {
        switcher.switchSpace(direction: direction)
    }

    func refreshStatus() {
        accessibilityGranted = AXIsProcessTrusted()
        launchAtLoginEnabled = LoginItemManager.isEnabled
        cliInstalled = CLIInstaller.isInstalled()
    }

    func requestAccessibilityPermission() {
        InputPermissionManager.requestPrompt()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        try LoginItemManager.setEnabled(enabled)
        launchAtLoginEnabled = LoginItemManager.isEnabled
    }

    func startMonitoringIfPossible() {
        _ = switcher.startMonitoring()
    }
}
