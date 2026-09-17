import SwiftUI
import AppKit
import os

private let appLog = Logger(subsystem: "com.instant-swipe.iss", category: "app")

@main
struct ISSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    static let mainWindowID = "main"

    var body: some Scene {
        WindowGroup("Instant Space Switcher", id: ISSApp.mainWindowID) {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra(
            "Instant Space Switcher",
            systemImage: "rectangle.split.2x1",
            isInserted: Binding(
                get: { model.showMenuBarItem },
                // One-way: the app owns this setting. MenuBarExtra echoes the
                // binding back during scene updates with a stale value, which
                // would both publish inside a view update and revert the
                // toggle — so ignore its write-backs.
                set: { _ in }
            )
        ) {
            MenuBarContent()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.menu)
    }
}

enum ISSDefaults {
    static let showMenuBarItem = "showMenuBarItem"
}

private struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Switch Left") { _ = model.switchSpace(.left) }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        Button("Switch Right") { _ = model.switchSpace(.right) }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

        Divider()

        Text(model.accessibilityGranted ? "Accessibility: Granted" : "Accessibility: Missing")
        Text(model.launchAtLoginEnabled ? "Launch at Login: On" : "Launch at Login: Off")

        Divider()

        Button("Open Window") {
            // Switch out of accessory mode first so the Dock icon and window
            // can come to the front, then activate once the window exists.
            NSApp.setActivationPolicy(.regular)
            openWindow(id: ISSApp.mainWindowID)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows
                    .first { $0.canBecomeMain && !$0.isExcludedFromWindowsMenu }?
                    .makeKeyAndOrderFront(nil)
            }
        }

        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Hides the Dock icon while no window is open. The menubar item remains the
/// only visible presence; opening the window restores the regular Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when the system launched the app as a login item, or when
    /// ISS_START_HIDDEN=1 is set (for testing without logging out).
    private var startHidden = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        startHidden = AppDelegate.launchedAsLoginItem()
            || ProcessInfo.processInfo.environment["ISS_START_HIDDEN"] == "1"
        if startHidden {
            // Menu bar only: no Dock icon, and don't steal focus at login.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        if startHidden {
            // SwiftUI opens the WindowGroup's window regardless; close it on
            // the next run loop tick, before it has a chance to be used.
            DispatchQueue.main.async {
                let windows = NSApp.windows.filter { $0.canBecomeMain && !$0.isExcludedFromWindowsMenu }
                windows.forEach { $0.close() }
                NSApp.setActivationPolicy(.accessory)
                appLog.info("started hidden (login item); closed \(windows.count) window(s)")
            }
        }
    }

    /// Login items launched by the system carry an open-application Apple
    /// event whose property data is keyAELaunchedAsLogInItem.
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication),
              let propData = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)) else {
            return false
        }
        return propData.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Relaunching the app (e.g. from Finder) while it is running with no
    /// window — the escape hatch when the menubar item is also hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }

    @objc private func windowWillClose(_ note: Notification) {
        // willCloseNotification fires before the window leaves the list, so
        // check on the next runloop tick whether any real window survives.
        DispatchQueue.main.async {
            if !AppDelegate.hasVisibleAppWindow() {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    static func hasVisibleAppWindow() -> Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain && !window.isExcludedFromWindowsMenu
        }
    }
}
