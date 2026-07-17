import Foundation
import Darwin
import DontSleepShared

protocol AppLivenessMonitoring {
    func appIsAlive() -> Bool
}

protocol AdvisoryLockProbing {
    func lockIsHeld(at url: URL) -> Bool
}

struct AdvisoryLockProbe: AdvisoryLockProbing {
    func lockIsHeld(at url: URL) -> Bool {
        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(descriptor, F_GETLK, &lock) != -1 else { return false }
        return lock.l_type != Int16(F_UNLCK)
    }
}

struct AppLivenessMonitor: AppLivenessMonitoring {
    let lockProbe: AdvisoryLockProbing
    let runLockURL: URL

    init(homeDirectory: URL, fileSystem: SupervisorFileSystem = LocalSupervisorFileSystem()) {
        self.lockProbe = AdvisoryLockProbe()
        self.runLockURL = LaunchAgentContract.runLockURL(homeDirectory: homeDirectory)
    }

    init(runLockURL: URL, fileSystem: SupervisorFileSystem) {
        self.lockProbe = AdvisoryLockProbe()
        self.runLockURL = runLockURL
    }

    init(runLockURL: URL, lockProbe: AdvisoryLockProbing) {
        self.runLockURL = runLockURL
        self.lockProbe = lockProbe
    }

    func appIsAlive() -> Bool {
        lockProbe.lockIsHeld(at: runLockURL)
    }
}
