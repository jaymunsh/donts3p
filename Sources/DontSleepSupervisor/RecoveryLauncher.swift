import Foundation
import AppKit
import DontSleepShared

protocol RecoveryLaunching {
    func launchRecovery() throws
}

enum RecoveryLaunchError: Error {
    case applicationMissing
    case completionTimedOut
    case launchRejected(Error)
}

protocol RecoveryApplicationOpening {
    func openApplication(at url: URL, arguments: [String], completion: @escaping (Error?) -> Void)
}

struct LaunchServicesApplicationOpener: RecoveryApplicationOpening {
    func openApplication(at url: URL, arguments: [String], completion: @escaping (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            completion(error)
        }
    }
}

struct LaunchServicesRecoveryLauncher: RecoveryLaunching {
    static let completionTimeout: DispatchTimeInterval = .seconds(10)

    let applicationURL: URL
    let opener: RecoveryApplicationOpening
    let timeout: DispatchTimeInterval

    init(
        applicationURL: URL = LaunchAgentContract.applicationURL,
        opener: RecoveryApplicationOpening = LaunchServicesApplicationOpener(),
        timeout: DispatchTimeInterval = LaunchServicesRecoveryLauncher.completionTimeout
    ) {
        self.applicationURL = applicationURL
        self.opener = opener
        self.timeout = timeout
    }

    func launchRecovery() throws {
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw RecoveryLaunchError.applicationMissing
        }
        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        opener.openApplication(at: applicationURL, arguments: [LaunchAgentContract.recoveryArgument]) { error in
            launchError = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw RecoveryLaunchError.completionTimedOut
        }
        if let launchError {
            throw RecoveryLaunchError.launchRejected(launchError)
        }
    }
}
