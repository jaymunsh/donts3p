import Combine
import AppKit
import Foundation
import DontSleepShared

protocol ProcessTerminating {
    func terminate()
}

struct ApplicationTerminator: ProcessTerminating {
    func terminate() { NSApp.terminate(nil) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var desiredActive = false
    @Published private(set) var isBatteryWarningVisible = false
    @Published private(set) var terminalOffDiagnostic: String?
    @Published private(set) var observation: AssertionObservation
    @Published private(set) var isSystemSleepOverrideWarningVisible = false
    @Published private(set) var isSystemSleepOverrideEnabled = false
    @Published private(set) var hasPendingSystemSleepOverrideRestore = false
    @Published private(set) var systemSleepOverrideObservedState: SystemSleepOverrideObservedState = .unknown
    @Published private(set) var systemSleepOverrideDiagnostic: String?

    let controller: SleepAssertionController
    private let intentStore: IntentStoring
    private let recoveryManager: RecoveryManaging
    private let powerSourceMonitor: PowerSourceMonitor
    private let terminator: ProcessTerminating
    private let systemSleepOverrideController: SystemSleepOverrideControlling
    private var releaseRetryIndex = 0
    private var createRetryIndex = 0
    private var createRetryTimer: Timer?
    private var releaseRetryTimer: Timer?
    private var samplingTimer: Timer?
    private var notificationObservers: [NSObjectProtocol] = []
    private var pendingTermination = false
    private var hasTerminated = false

    init(controller: SleepAssertionController = SleepAssertionController(), intentStore: IntentStoring = IntentStore(), recoveryManager: RecoveryManaging = RecoveryManager(), powerSourceMonitor: PowerSourceMonitor = PowerSourceMonitor(), systemSleepOverrideController: SystemSleepOverrideControlling = SystemSleepOverrideController(), terminator: ProcessTerminating = ApplicationTerminator()) {
        self.controller = controller
        self.intentStore = intentStore
        self.recoveryManager = recoveryManager
        self.powerSourceMonitor = powerSourceMonitor
        self.systemSleepOverrideController = systemSleepOverrideController
        self.terminator = terminator
        self.observation = controller.observation
        self.isSystemSleepOverrideEnabled = systemSleepOverrideController.isEnabled
        self.systemSleepOverrideDiagnostic = systemSleepOverrideController.diagnostic
        self.hasPendingSystemSleepOverrideRestore = systemSleepOverrideController.hasPendingRestore
        self.systemSleepOverrideObservedState = systemSleepOverrideController.observedState
    }

    deinit {
        createRetryTimer?.invalidate()
        releaseRetryTimer?.invalidate()
        samplingTimer?.invalidate()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        powerSourceMonitor.stopObserving()
    }

    var isProtected: Bool { observation.isFreshActive() }

    /// A recovery launch never invents intent; an ordinary launch always enables it.
    func launch(recovery: Bool) {
        do {
            let storedIntent = try intentStore.storedDesiredActive()
            if recovery {
                guard storedIntent == true else {
                    terminator.terminate()
                    return
                }
                desiredActive = true
                controller.enable()
                refreshObservation()
                refreshPowerSource()
            } else {
                enableAndActivate()
            }
        } catch {
            desiredActive = false
            terminalOffDiagnostic = "Unable to restore sleep-prevention state: \(error)"
        }
        installLifecycle()
    }

    /// Persists intent before registering recovery and acquiring the assertion.
    func enableAndActivate() {
        guard !desiredActive else {
            refreshObservation()
            return
        }
        do {
            try intentStore.setDesiredActive(true)
            do {
                try recoveryManager.enableRecovery()
            } catch {
                try intentStore.setDesiredActive(false)
                throw error
            }
            desiredActive = true
            terminalOffDiagnostic = nil
            releaseRetryTimer?.invalidate()
            releaseRetryTimer = nil
            controller.enable()
            refreshObservation()
            scheduleCreateRetryIfNeeded()
            refreshPowerSource()
        } catch {
            desiredActive = false
            terminalOffDiagnostic = "Unable to enable sleep prevention: \(error)"
        }
    }

    /// False intent and recovery removal always precede assertion release.
    func disable() {
        createRetryTimer?.invalidate()
        createRetryTimer = nil
        createRetryIndex = 0
        releaseRetryIndex = 0
        do {
            try intentStore.setDesiredActive(false)
            desiredActive = false
        } catch {
            terminalOffDiagnostic = "Unable to persist disabled sleep-prevention intent: \(error)"
            return
        }

        do {
            try recoveryManager.disableRecovery()
            terminalOffDiagnostic = nil
        } catch {
            terminalOffDiagnostic = "Unable to disable recovery: \(error)"
        }

        attemptRelease()
        scheduleReleaseRetryIfNeeded()
    }

    func quit() {
        pendingTermination = true
        disable()
        terminateWhenClean()
    }

    func requestSystemSleepOverrideEnable() {
        isSystemSleepOverrideWarningVisible = true
    }

    func cancelSystemSleepOverrideEnable() {
        isSystemSleepOverrideWarningVisible = false
    }

    func confirmSystemSleepOverrideEnable() {
        isSystemSleepOverrideWarningVisible = false
        do {
            try systemSleepOverrideController.enable()
            refreshSystemSleepOverride()
        } catch {
            refreshSystemSleepOverride()
            systemSleepOverrideDiagnostic = error.localizedDescription
        }
    }

    func restoreSystemSleepOverride() {
        do {
            try systemSleepOverrideController.restore()
            refreshSystemSleepOverride()
        } catch {
            refreshSystemSleepOverride()
            systemSleepOverrideDiagnostic = error.localizedDescription
        }
    }

    private func refreshSystemSleepOverride() {
        systemSleepOverrideController.refresh()
        isSystemSleepOverrideEnabled = systemSleepOverrideController.isEnabled
        hasPendingSystemSleepOverrideRestore = systemSleepOverrideController.hasPendingRestore
        systemSleepOverrideObservedState = systemSleepOverrideController.observedState
        systemSleepOverrideDiagnostic = systemSleepOverrideController.diagnostic
    }

    func retryPendingRelease() {
        guard !desiredActive else { return }
        releaseRetryTimer?.invalidate()
        releaseRetryTimer = nil
        attemptRelease()
        scheduleReleaseRetryIfNeeded()
    }

    func handleWakeOrActivation() {
        refreshObservation()
        if desiredActive { scheduleCreateRetryIfNeeded() }
        refreshPowerSource()
    }

    private func installLifecycle() {
        guard notificationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleWakeOrActivation() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleWakeOrActivation() }
            }
        ]
        powerSourceMonitor.startObserving { [weak self] in
            Task { @MainActor in self?.refreshPowerSource() }
        }
        samplingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handleWakeOrActivation() }
        }
        if desiredActive { scheduleCreateRetryIfNeeded() } else { scheduleReleaseRetryIfNeeded() }
    }

    private func refreshObservation() {
        controller.sample()
        observation = controller.observation
    }

    private func refreshPowerSource() {
        isBatteryWarningVisible = powerSourceMonitor.sample()
        if powerSourceMonitor.bootIDUnavailable {
            terminalOffDiagnostic = "Unable to determine the current boot session; battery warnings will not be deduplicated."
        }
    }

    private func scheduleCreateRetryIfNeeded() {
        guard desiredActive, !isProtected, createRetryTimer == nil else { return }
        let delays: [TimeInterval] = [1, 5, 30]
        let delay = createRetryIndex < delays.count ? delays[createRetryIndex] : 300
        createRetryIndex += 1
        createRetryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.createRetryTimer = nil
                guard self.desiredActive else { return }
                self.controller.enable()
                self.refreshObservation()
                if self.isProtected {
                    self.createRetryIndex = 0
                } else {
                    self.scheduleCreateRetryIfNeeded()
                }
            }
        }
    }

    private func scheduleReleaseRetryIfNeeded() {
        guard !desiredActive, controller.ownedAssertionStillExists(), releaseRetryTimer == nil else {
            terminateWhenClean()
            return
        }
        let delays: [TimeInterval] = [1, 5, 30]
        guard releaseRetryIndex < delays.count else {
            classifyFinalReleaseState()
            return
        }
        let delay = delays[releaseRetryIndex]
        releaseRetryIndex += 1
        releaseRetryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.releaseRetryTimer = nil
                self.retryPendingRelease()
            }
        }
    }

    private func attemptRelease() {
        if controller.release() {
            releaseRetryIndex = 0
            refreshObservation()
            terminateWhenClean()
        }
    }

    private func classifyFinalReleaseState() {
        if controller.ownedAssertionStillExists() {
            terminalOffDiagnostic = "Unable to release sleep assertion after retries; quitting to let process teardown release it."
            terminateOnce()
        } else {
            terminalOffDiagnostic = nil
            terminateWhenClean()
        }
    }

    private func terminateWhenClean() {
        guard pendingTermination, !controller.ownedAssertionStillExists() else { return }
        terminateOnce()
    }

    private func terminateOnce() {
        guard !hasTerminated else { return }
        hasTerminated = true
        terminator.terminate()
    }
}
