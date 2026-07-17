import IOKit.pwr_mgt
import XCTest
@testable import donts3p

@MainActor
final class AppModelTests: XCTestCase {
    func testRecoveryLaunchHonorsDurableIntentWithoutReconciliation() {
        let intent = Intent(stored: true)
        let recovery = Recovery()
        let model = makeModel(intent: intent, recovery: recovery)
        model.launch(recovery: true)
        XCTAssertTrue(model.desiredActive)
        XCTAssertTrue(model.isProtected)
        XCTAssertTrue(recovery.events.isEmpty)
    }

    func testFirstNormalLaunchEnablesIntentAndRecoveryBeforeAssertion() {
        let events = EventLog()
        let intent = Intent(stored: nil, events: events)
        let recovery = Recovery(events: events)
        let model = makeModel(intent: intent, recovery: recovery, events: events)
        model.launch(recovery: false)
        XCTAssertTrue(model.desiredActive)
        XCTAssertEqual(events.events, ["intent:true", "recovery:enable", "create"])
    }
    func testFirstNormalLaunchPublishesBatteryWarningSynchronously() {
        let warningStore = Warnings()
        let model = AppModel(
            controller: SleepAssertionController(provider: AssertionProvider(events: EventLog())),
            intentStore: Intent(stored: nil),
            recoveryManager: Recovery(),
            powerSourceMonitor: PowerSourceMonitor(provider: Battery(), store: warningStore, bootID: "boot"),
            terminator: Terminator()
        )

        model.launch(recovery: false)

        XCTAssertTrue(model.isBatteryWarningVisible)
        XCTAssertTrue(warningStore.warned)
    }

    func testFirstNormalLaunchPublishesMissingBootIDDiagnosticSynchronously() {
        let model = AppModel(
            controller: SleepAssertionController(provider: AssertionProvider(events: EventLog())),
            intentStore: Intent(stored: nil),
            recoveryManager: Recovery(),
            powerSourceMonitor: PowerSourceMonitor(provider: Battery(), store: Warnings(), bootSessionIdentifier: MissingBootID()),
            terminator: Terminator()
        )

        model.launch(recovery: false)

        XCTAssertTrue(model.isBatteryWarningVisible)
        XCTAssertEqual(model.terminalOffDiagnostic, "Unable to determine the current boot session; battery warnings will not be deduplicated.")
    }


    func testNormalLaunchWithStoredFalsePerformsFullEnable() {
        let events = EventLog()
        let intent = Intent(stored: false, events: events)
        let model = makeModel(intent: intent, recovery: Recovery(events: events), events: events)

        model.launch(recovery: false)

        XCTAssertTrue(model.desiredActive)
        XCTAssertEqual(events.events, ["intent:true", "recovery:enable", "create"])
    }

    func testFalseRecoveryLaunchTerminatesWithoutMutationOrLifecycle() {
        let events = EventLog()
        let terminator = Terminator(events: events)
        let model = makeModel(intent: Intent(stored: false, events: events), recovery: Recovery(events: events), terminator: terminator, events: events)

        model.launch(recovery: true)

        XCTAssertEqual(events.events, ["terminate"])
        XCTAssertFalse(model.desiredActive)
    }

    func testRegistrationFailureRollsIntentBackBeforeCreatingAssertion() {
        let events = EventLog()
        let intent = Intent(stored: false, events: events)
        let model = makeModel(intent: intent, recovery: Recovery(enableError: Failure.failed, events: events), events: events)
        model.enableAndActivate()
        XCTAssertFalse(model.desiredActive)
        XCTAssertEqual(events.events, ["intent:true", "recovery:enable", "intent:false"])
        XCTAssertNotNil(model.terminalOffDiagnostic)
    }

    func testOffPersistsFalseBeforeRecoveryRemovalAndRelease() {
        let events = EventLog()
        let intent = Intent(stored: true, events: events)
        let model = makeModel(intent: intent, recovery: Recovery(events: events), events: events)
        model.launch(recovery: true)
        events.events.removeAll()
        model.disable()
        XCTAssertEqual(events.events, ["intent:false", "recovery:disable", "release"])
    }
    func testOffReleasesAssertionWhenRecoveryUnregisterFails() {
        let events = EventLog()
        let recovery = Recovery(disableError: Failure.failed, events: events)
        let model = makeModel(intent: Intent(stored: true, events: events), recovery: recovery, events: events)
        model.launch(recovery: true)
        events.events.removeAll()

        model.disable()

        XCTAssertEqual(events.events, ["intent:false", "recovery:disable", "release"])
        XCTAssertEqual(model.terminalOffDiagnostic, "Unable to disable recovery: failed")
    }
    func testReleaseClassifiesOnlyAfterInitialAttemptAndThreeRetries() {
        let events = EventLog()
        let model = AppModel(
            controller: SleepAssertionController(provider: FlakyAssertionProvider(events: events, failures: 4)),
            intentStore: Intent(stored: true, events: events),
            recoveryManager: Recovery(events: events),
            powerSourceMonitor: PowerSourceMonitor(provider: AC(), store: Warnings(), bootID: "boot"),
            terminator: Terminator(events: events)
        )
        model.launch(recovery: true)
        events.events.removeAll()

        model.disable()
        model.retryPendingRelease()
        model.retryPendingRelease()
        model.retryPendingRelease()

        XCTAssertEqual(events.events, [
            "intent:false", "recovery:disable",
            "release", "release", "release", "release", "terminate",
        ])
        XCTAssertEqual(model.terminalOffDiagnostic, "Unable to release sleep assertion after retries; quitting to let process teardown release it.")
    }

    func testQuitCleansUpBeforeTermination() {
        let events = EventLog()
        let terminator = Terminator(events: events)
        let model = makeModel(intent: Intent(stored: true, events: events), recovery: Recovery(events: events), terminator: terminator, events: events)
        model.launch(recovery: true)
        events.events.removeAll()
        model.quit()
        XCTAssertEqual(events.events, ["intent:false", "recovery:disable", "release", "terminate"])
    }
    func testQuitTerminatesAfterPendingReleaseEventuallySucceeds() {
        let events = EventLog()
        let provider = FlakyAssertionProvider(events: events, failures: 1)
        let model = AppModel(
            controller: SleepAssertionController(provider: provider),
            intentStore: Intent(stored: true, events: events),
            recoveryManager: Recovery(events: events),
            powerSourceMonitor: PowerSourceMonitor(provider: AC(), store: Warnings(), bootID: "boot"),
            terminator: Terminator(events: events)
        )
        model.launch(recovery: true)
        events.events.removeAll()
        model.quit()
        XCTAssertEqual(events.events, ["intent:false", "recovery:disable", "release"])
        model.retryPendingRelease()
        XCTAssertEqual(events.events, ["intent:false", "recovery:disable", "release", "release", "terminate"])
    }

    private func makeModel(intent: Intent, recovery: Recovery, terminator: Terminator = Terminator(), events: EventLog = EventLog()) -> AppModel {
        AppModel(controller: SleepAssertionController(provider: AssertionProvider(events: events)), intentStore: intent, recoveryManager: recovery, powerSourceMonitor: PowerSourceMonitor(provider: AC(), store: Warnings(), bootID: "boot"), terminator: terminator)
    }
}

private enum Failure: Error { case failed }
private final class EventLog { var events: [String] = [] }
private final class Intent: IntentStoring {
    var stored: Bool?
    let events: EventLog?
    init(stored: Bool?, events: EventLog? = nil) { self.stored = stored; self.events = events }
    func desiredActive() throws -> Bool { stored ?? false }
    func storedDesiredActive() throws -> Bool? { stored }
    func setDesiredActive(_ active: Bool) throws { stored = active; events?.events.append("intent:\(active)") }
}
private final class Recovery: RecoveryManaging {
    let enableError: Error?
    let disableError: Error?
    let events: EventLog
    init(enableError: Error? = nil, disableError: Error? = nil, events: EventLog = EventLog()) {
        self.enableError = enableError
        self.disableError = disableError
        self.events = events
    }
    func enableRecovery() throws { events.events.append("recovery:enable"); if let enableError { throw enableError } }
    func disableRecovery() throws { events.events.append("recovery:disable"); if let disableError { throw disableError } }
}
private final class AC: PowerSourceProviding { func powerSourceState() -> PowerSourceState { .AC } }
private final class Warnings: BatteryWarningStoring {
    var warned = false
    func warnedOnBattery(bootID: String) -> Bool { warned }
    func setWarnedOnBattery(_ warned: Bool, bootID: String) { self.warned = warned }
}
private final class Battery: PowerSourceProviding { func powerSourceState() -> PowerSourceState { .battery } }
private final class MissingBootID: BootSessionIdentifying { func bootSessionID() -> String? { nil } }
private final class Terminator: ProcessTerminating { let events: EventLog?; init(events: EventLog? = nil) { self.events = events }; func terminate() { events?.events.append("terminate") } }
private final class AssertionProvider: SleepAssertionProviding {
    let events: EventLog; init(events: EventLog) { self.events = events }
    func create() throws -> IOPMAssertionID { events.events.append("create"); return 1 }
    func release(_ id: IOPMAssertionID) throws { events.events.append("release") }
    func isOwnedAssertionActive(_ id: IOPMAssertionID) throws -> Bool { true }
}
private final class FlakyAssertionProvider: SleepAssertionProviding {
    let events: EventLog
    var failures: Int
    var active = true

    init(events: EventLog, failures: Int) {
        self.events = events
        self.failures = failures
    }

    func create() throws -> IOPMAssertionID { events.events.append("create"); return 1 }

    func release(_ id: IOPMAssertionID) throws {
        events.events.append("release")
        if failures > 0 {
            failures -= 1
            throw Failure.failed
        }
        active = false
    }

    func isOwnedAssertionActive(_ id: IOPMAssertionID) throws -> Bool { active }
}
