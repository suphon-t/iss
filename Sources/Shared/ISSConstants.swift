import Foundation

public enum ISSConstants {
    public static let machServiceName = "com.instant-swipe.issd"
    public static let daemonPlistName = "com.instant-swipe.issd.plist"
    public static let cliExecutableName = "issctl"
    public static let cliInstallDirectory = "/usr/local/bin"
    public static var cliInstallPath: String { cliInstallDirectory + "/" + cliExecutableName }
}

@objc public enum SpaceDirection: Int {
    case left = -1
    case right = 1
}
