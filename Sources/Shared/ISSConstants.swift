import Foundation

public enum ISSConstants {
    /// Distributed-notification name the CLI posts to ask the running app to
    /// switch spaces. Payload is encoded in the notification's object string.
    public static let switchRequestName = "com.instant-swipe.iss.switchRequest"
    /// Distributed-notification name the app posts back with the outcome.
    public static let switchReplyName = "com.instant-swipe.iss.switchReply"

    public static let cliExecutableName = "issctl"
    public static let cliInstallDirectory = "/usr/local/bin"
    public static var cliInstallPath: String { cliInstallDirectory + "/" + cliExecutableName }
}

public enum SpaceDirection: Int {
    case left = -1
    case right = 1
}
