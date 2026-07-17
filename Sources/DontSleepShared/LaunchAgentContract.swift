import Foundation

public enum LaunchAgentContract {
    public static let appBundleIdentifier = "org.donts3p"
    public static let recoveryLabel = "org.donts3p.recovery"
    public static let applicationURL = URL(fileURLWithPath: "/Applications/donts3p.app")

    // Legacy values are retained exclusively to deactivate old recovery agents
    // during an in-place upgrade.
    public static let legacyRecoveryLabel = "org.dontsleep.recovery"
    public static let legacyStateDirectoryName = "org.dontsleep"
    public static let recoveryArgument = "--recover"

    public static func stateDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(appBundleIdentifier, isDirectory: true)
    }

    public static func intentMarkerURL(homeDirectory: URL) -> URL {
        stateDirectory(homeDirectory: homeDirectory).appendingPathComponent("recovery.enabled")
    }

    public static func runLockURL(homeDirectory: URL) -> URL {
        stateDirectory(homeDirectory: homeDirectory).appendingPathComponent("run.lock")
    }

    public static func activationSocketURL(homeDirectory: URL) -> URL {
        stateDirectory(homeDirectory: homeDirectory).appendingPathComponent("activate.sock")
    }

    public static func recoveryLeaseURL(homeDirectory: URL) -> URL {
        stateDirectory(homeDirectory: homeDirectory).appendingPathComponent("recovery.lease")
    }

    public static func recoveryDegradedURL(homeDirectory: URL) -> URL {
        stateDirectory(homeDirectory: homeDirectory).appendingPathComponent("recovery.degraded")
    }

}
