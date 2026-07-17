import XCTest
@testable import donts3p

final class SystemSleepOverrideTests: XCTestCase {
    func testParsesDistinctValuesForEachPowerProfile() throws {
        let snapshot = SystemSleepOverrideController.disablesleepSnapshot(in: """
        Battery Power:
         disablesleep 0
        AC Power:
         disablesleep 1
        UPS Power:
         disablesleep 0
        """)
        XCTAssertEqual(snapshot, try SystemSleepOverrideSnapshot(batteryPower: 0, acPower: 1, upsPower: 0))
    }

    func testRejectsInvalidProfileValuesAndTreatsMissingKeyAsDefaultOff() throws {
        XCTAssertNil(SystemSleepOverrideController.disablesleepSnapshot(in: "AC Power:\n disablesleep 2\n"))
        XCTAssertNil(SystemSleepOverrideController.disablesleepSnapshot(in: "AC Power:\n disablesleep 1 extra\n"))
        XCTAssertNil(SystemSleepOverrideController.disablesleepSnapshot(in: "sleep 0\n"))
        XCTAssertEqual(
            SystemSleepOverrideController.disablesleepSnapshot(in: "Battery Power:\n sleep 1\nAC Power:\n sleep 0\n"),
            try SystemSleepOverrideSnapshot(batteryPower: 0, acPower: 0)
        )
    }

    func testEnableUsesFixedAllProfilesCommandAndPersistsSnapshot() throws {
        let prior = pmsetOutput(battery: 0, ac: 1, ups: 0)
        let enabled = pmsetOutput(battery: 1, ac: 1, ups: 1)
        let runner = Runner(outputs: [prior, prior, enabled])
        let store = Store()
        let controller = SystemSleepOverrideController(runner: runner, store: store, powerSourceProvider: Source(.AC))

        try controller.enable()

        XCTAssertEqual(store.snapshot, try SystemSleepOverrideSnapshot(batteryPower: 0, acPower: 1, upsPower: 0))
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(runner.calls.contains { $0.0 == "/usr/bin/osascript" && $0.1 == ["-e", "do shell script \"if /usr/bin/pmset -g batt | /usr/bin/grep -q 'AC Power'; then /usr/bin/pmset -a disablesleep 1; else exit 1; fi\" with administrator privileges"] })
    }

    func testRestoreUsesExactPerProfileCommandAndRemovesSnapshotAfterVerification() throws {
        let prior = try SystemSleepOverrideSnapshot(batteryPower: 0, acPower: 1, upsPower: 0)
        let runner = Runner(outputs: [pmsetOutput(battery: 1, ac: 1, ups: 1), pmsetOutput(battery: 0, ac: 1, ups: 0)])
        let store = Store(snapshot: prior)
        let controller = SystemSleepOverrideController(runner: runner, store: store, powerSourceProvider: Source(.AC))

        try controller.restore()

        XCTAssertNil(store.snapshot)
        XCTAssertTrue(runner.calls.contains { $0.0 == "/usr/bin/osascript" && $0.1 == ["-e", "do shell script \"/usr/bin/pmset -b disablesleep 0; /usr/bin/pmset -c disablesleep 1; /usr/bin/pmset -u disablesleep 0\" with administrator privileges"] })
        XCTAssertFalse(controller.hasPendingRestore)
        XCTAssertEqual(controller.observedState, .mixed)
    }

    func testBatteryPowerDoesNotEnableOverride() {
        let runner = Runner(outputs: [pmsetOutput(battery: 0, ac: 0, ups: 0)])
        let controller = SystemSleepOverrideController(runner: runner, store: Store(), powerSourceProvider: Source(.battery))

        XCTAssertThrowsError(try controller.enable()) { error in
            XCTAssertEqual(error as? SystemSleepOverrideError, .notOnACPower)
        }
        XCTAssertFalse(runner.calls.contains { $0.0 == "/usr/bin/osascript" })
    }

    func testFailedRestoreVerificationKeepsSavedSnapshotForRecovery() throws {
        let prior = try SystemSleepOverrideSnapshot(batteryPower: 0, acPower: 1, upsPower: 0)
        let runner = Runner(outputs: [pmsetOutput(battery: 1, ac: 1, ups: 1), pmsetOutput(battery: 0, ac: 0, ups: 0)])
        let store = Store(snapshot: prior)
        let controller = SystemSleepOverrideController(runner: runner, store: store, powerSourceProvider: Source(.AC))

        XCTAssertThrowsError(try controller.restore())
        XCTAssertEqual(store.snapshot, prior)
    }

    func testControllerRecreationRetainsRestoreOwnership() throws {
        let prior = try SystemSleepOverrideSnapshot(batteryPower: 0, acPower: 0, upsPower: 0)
        let store = Store(snapshot: prior)

        let controller = SystemSleepOverrideController(runner: Runner(outputs: [pmsetOutput(battery: 1, ac: 1, ups: 1)]), store: store, powerSourceProvider: Source(.AC))

        XCTAssertTrue(controller.hasPendingRestore)
        XCTAssertEqual(controller.observedState, .enabled)
    }

    func testMixedStateIsObservedWithoutClaimingEnabled() {
        let controller = SystemSleepOverrideController(runner: Runner(outputs: [pmsetOutput(battery: 1, ac: 0, ups: 1)]), store: Store(), powerSourceProvider: Source(.AC))

        XCTAssertEqual(controller.observedState, .mixed)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.hasPendingRestore)
    }

    func testQueryFailureIsReportedAsUnknown() {
        let runner = Runner(outputs: [], statuses: [1])
        let controller = SystemSleepOverrideController(runner: runner, store: Store(), powerSourceProvider: Source(.AC))

        XCTAssertEqual(controller.observedState, .unknown)
        XCTAssertEqual(controller.diagnostic, SystemSleepOverrideError.commandFailed("").localizedDescription)
    }

    func testExternalEnabledStateDoesNotCreateRestoreOwnership() {
        let controller = SystemSleepOverrideController(runner: Runner(outputs: [pmsetOutput(battery: 1, ac: 1, ups: 1)]), store: Store(), powerSourceProvider: Source(.AC))

        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.hasPendingRestore)
    }

    func testACChangingBeforeMutationPreventsPrivilegedCommandAndKeepsSnapshot() {
        let store = Store()
        let runner = Runner(outputs: [pmsetOutput(battery: 0, ac: 0, ups: 0), pmsetOutput(battery: 0, ac: 0, ups: 0)])
        let source = Source([.AC, .battery])
        let controller = SystemSleepOverrideController(runner: runner, store: store, powerSourceProvider: source)

        XCTAssertThrowsError(try controller.enable()) { error in
            XCTAssertEqual(error as? SystemSleepOverrideError, .notOnACPower)
        }
        XCTAssertNotNil(store.snapshot)
        XCTAssertFalse(runner.calls.contains { $0.0 == "/usr/bin/osascript" })
    }

    func testUnreadableSnapshotBlocksEnableWithEmergencyInstructions() {
        let store = Store(readError: NSError(domain: "test", code: 1))
        let controller = SystemSleepOverrideController(runner: Runner(outputs: [pmsetOutput(battery: 0, ac: 0, ups: 0)]), store: store, powerSourceProvider: Source(.AC))

        XCTAssertTrue(controller.diagnostic?.contains("Restore manually with: sudo /usr/bin/pmset -a disablesleep 0.") == true)
        XCTAssertThrowsError(try controller.enable()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Restore manually with: sudo /usr/bin/pmset -a disablesleep 0."))
        }
    }

    func testVerificationPreservesQueryFailure() throws {
        let prior = try SystemSleepOverrideSnapshot(batteryPower: 0, acPower: 0, upsPower: 0)
        let runner = Runner(outputs: [pmsetOutput(battery: 1, ac: 1, ups: 1), "verification failed"], statuses: [0, 1])
        let controller = SystemSleepOverrideController(runner: runner, store: Store(snapshot: prior), powerSourceProvider: Source(.AC))

        XCTAssertThrowsError(try controller.restore()) { error in
            XCTAssertEqual(error as? SystemSleepOverrideError, .commandFailed("verification failed"))
        }
    }

    func testDefaultStateIsOff() {
        let controller = SystemSleepOverrideController(runner: Runner(outputs: [pmsetOutput(battery: 0, ac: 0, ups: 0)]), store: Store(), powerSourceProvider: Source(.AC))
        XCTAssertFalse(controller.isEnabled)
    }
}

private func pmsetOutput(battery: Int, ac: Int, ups: Int) -> String {
    """
    Battery Power:
     disablesleep \(battery)
    AC Power:
     disablesleep \(ac)
    UPS Power:
     disablesleep \(ups)
    """
}

private final class Runner: SystemCommandRunning {
    var outputs: [String]
    var statuses: [Int32]
    var calls: [(String, [String])] = []

    init(outputs: [String], statuses: [Int32] = []) {
        self.outputs = outputs
        self.statuses = statuses
    }

    func run(executable: String, arguments: [String]) -> SystemCommandResult {
        calls.append((executable, arguments))
        if executable == "/usr/bin/pmset" {
            let status = statuses.isEmpty ? 0 : statuses.removeFirst()
            return SystemCommandResult(status: status, output: outputs.isEmpty ? "" : outputs.removeFirst())
        }
        return SystemCommandResult(status: 0, output: "")
    }
}

private final class Store: SystemSleepOverrideStoring {
    var snapshot: SystemSleepOverrideSnapshot?
    let readError: Error?

    init(snapshot: SystemSleepOverrideSnapshot? = nil, readError: Error? = nil) {
        self.snapshot = snapshot
        self.readError = readError
    }

    func savedSnapshot() throws -> SystemSleepOverrideSnapshot? {
        if let readError { throw readError }
        return snapshot
    }
    func saveSnapshot(_ snapshot: SystemSleepOverrideSnapshot) throws { self.snapshot = snapshot }
    func removeSavedSnapshot() throws { snapshot = nil }
}

private final class Source: PowerSourceProviding {
    var states: [PowerSourceState]
    init(_ state: PowerSourceState) { states = [state] }
    init(_ states: [PowerSourceState]) { self.states = states }
    func powerSourceState() -> PowerSourceState { states.count > 1 ? states.removeFirst() : (states.first ?? .battery) }
}
