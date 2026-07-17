import Foundation
import Darwin
import DontSleepShared

protocol RecoveryAttemptScheduling {
    func wait(seconds: TimeInterval)
}

struct SystemRecoveryAttemptScheduler: RecoveryAttemptScheduling {
    func wait(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

enum SupervisorResult: Equatable {
    case success
    case failure
}
private enum RecoveryState {
    case recovering
    case handoff(remaining: TimeInterval)
    case awaitingLeaseExpiry
    case degraded
}

private struct DegradedRecoveryState: Codable {
    let lastLaunchFailureType: String
    let lastLaunchFailureTimestamp: String
    let attemptCount: Int
    let bootID: String
    let machContinuousTicks: UInt64
}


struct RecoverySupervisor {
    static let retryDelays: [TimeInterval] = [1, 5, 30]
    static let monitorInterval: TimeInterval = 1
    static let launchServicesBudget: TimeInterval = 10
    static let handoffBudget: TimeInterval = 10
    static let leaseBudgetSeconds: TimeInterval = retryDelays.reduce(0, +)
        + (Double(retryDelays.count + 1) * launchServicesBudget)
        + handoffBudget

    let intentStore: IntentMarkerStore
    let livenessMonitor: AppLivenessMonitoring
    let leaseStore: RecoveryLaunchLeaseStore
    let launcher: RecoveryLaunching
    let scheduler: RecoveryAttemptScheduling
    let fileSystem: SupervisorFileSystem
    let degradedStateURL: URL
    let leaseDurationTicks: UInt64

    init(
        homeDirectory: URL,
        fileSystem: SupervisorFileSystem = LocalSupervisorFileSystem(),
        clock: RecoveryClock = SystemRecoveryClock(),
        bootIdentifier: BootIdentifying = SystemBootIdentifier(),
        launcher: RecoveryLaunching = LaunchServicesRecoveryLauncher(),
        scheduler: RecoveryAttemptScheduling = SystemRecoveryAttemptScheduler(),
        leaseDurationTicks: UInt64 = RecoverySupervisor.defaultLeaseDurationTicks()
    ) {
        self.intentStore = IntentMarkerStore(homeDirectory: homeDirectory, fileSystem: fileSystem)
        self.livenessMonitor = AppLivenessMonitor(homeDirectory: homeDirectory, fileSystem: fileSystem)
        self.leaseStore = RecoveryLaunchLeaseStore(homeDirectory: homeDirectory, fileSystem: fileSystem, clock: clock, bootIdentifier: bootIdentifier)
        self.launcher = launcher
        self.scheduler = scheduler
        self.fileSystem = fileSystem
        self.degradedStateURL = LaunchAgentContract.recoveryDegradedURL(homeDirectory: homeDirectory)
        self.leaseDurationTicks = leaseDurationTicks
    }

    init(intentStore: IntentMarkerStore, livenessMonitor: AppLivenessMonitoring, leaseStore: RecoveryLaunchLeaseStore, launcher: RecoveryLaunching, scheduler: RecoveryAttemptScheduling, fileSystem: SupervisorFileSystem, degradedStateURL: URL, leaseDurationTicks: UInt64) {
        self.intentStore = intentStore
        self.livenessMonitor = livenessMonitor
        self.leaseStore = leaseStore
        self.launcher = launcher
        self.scheduler = scheduler
        self.fileSystem = fileSystem
        self.degradedStateURL = degradedStateURL
        self.leaseDurationTicks = leaseDurationTicks
    }

    func run() -> SupervisorResult {
        var ownedLease: RecoveryLaunchLease?
        var recoveryState: RecoveryState = fileSystem.fileExists(at: degradedStateURL) ? .degraded : .recovering

        do {
            while try intentStore.recoveryIsEnabled() {
                if livenessMonitor.appIsAlive() {
                    if let lease = ownedLease {
                        try leaseStore.clear(lease)
                        ownedLease = nil
                    }
                    clearDegradedState()
                    recoveryState = .recovering
                    scheduler.wait(seconds: Self.monitorInterval)
                    continue
                }

                if case .awaitingLeaseExpiry = recoveryState {
                    if try leaseStore.activeLease() != nil {
                        scheduler.wait(seconds: Self.monitorInterval)
                        continue
                    }
                    ownedLease = nil
                    recoveryState = .recovering
                    continue
                }

                if case .degraded = recoveryState {
                    scheduler.wait(seconds: Self.monitorInterval)
                    continue
                }

                if ownedLease == nil {
                    ownedLease = try leaseStore.acquire(validForTicks: leaseDurationTicks)
                }
                guard var lease = ownedLease else {
                    scheduler.wait(seconds: Self.monitorInterval)
                    continue
                }

                if case .handoff(let remaining) = recoveryState {
                    lease = try leaseStore.renew(lease, validForTicks: leaseDurationTicks)
                    ownedLease = lease
                    recoveryState = remaining > Self.monitorInterval
                        ? .handoff(remaining: remaining - Self.monitorInterval)
                        : .awaitingLeaseExpiry
                    scheduler.wait(seconds: Self.monitorInterval)
                    continue
                }

                var lastLaunchFailure: Error?
                var launched = false
                for attempt in 0...Self.retryDelays.count {
                    if attempt > 0 { scheduler.wait(seconds: Self.retryDelays[attempt - 1]) }
                    lease = try leaseStore.renew(lease, validForTicks: leaseDurationTicks)
                    ownedLease = lease
                    do {
                        try launcher.launchRecovery()
                        launched = true
                        break
                    } catch {
                        lastLaunchFailure = error
                    }
                }

                if launched {
                    recoveryState = .handoff(remaining: Self.handoffBudget)
                } else {
                    try persistDegradedState(lastLaunchFailure, attemptCount: Self.retryDelays.count + 1)
                    recoveryState = .degraded
                }

                scheduler.wait(seconds: Self.monitorInterval)
            }
            return .success
        } catch {
            return .failure
        }
    }

    private func clearDegradedState() {
        try? fileSystem.removeItem(at: degradedStateURL)
    }

    private func persistDegradedState(_ error: Error?, attemptCount: Int) throws {
        let failureType = error.map { String(reflecting: type(of: $0)).prefix(256) } ?? "unknown"
        let state = DegradedRecoveryState(
            lastLaunchFailureType: String(failureType),
            lastLaunchFailureTimestamp: ISO8601DateFormatter().string(from: Date()),
            attemptCount: attemptCount,
            bootID: try leaseStore.bootIdentifier.bootIdentifier(),
            machContinuousTicks: leaseStore.clock.continuousTimeTicks()
        )
        try fileSystem.writeAtomically(try JSONEncoder().encode(state), to: degradedStateURL)
    }

    static func defaultLeaseDurationTicks() -> UInt64 {
        let budgetSeconds = leaseBudgetSeconds
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer != 0 else {
            return UInt64(budgetSeconds * 1_000_000_000)
        }
        return (UInt64(budgetSeconds * 1_000_000_000) * UInt64(timebase.denom)) / UInt64(timebase.numer)
    }
}

let supervisor = RecoverySupervisor(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
exit(supervisor.run() == .success ? EXIT_SUCCESS : EXIT_FAILURE)
