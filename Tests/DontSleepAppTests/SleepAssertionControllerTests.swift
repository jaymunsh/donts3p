import IOKit.pwr_mgt
import XCTest
@testable import donts3p
import DontSleepShared

final class SleepAssertionControllerTests: XCTestCase {
    func testActiveSampleIsFreshAtZeroAge() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let observation = AssertionObservation(state: .active, sampledAt: now)

        XCTAssertTrue(observation.isFreshActive(now: now))
    }

    func testActiveSampleIsFreshAtExactMaximumAge() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let observation = AssertionObservation(state: .active, sampledAt: now.addingTimeInterval(-35))

        XCTAssertTrue(observation.isFreshActive(now: now, maximumAge: 35))
    }

    func testActiveSampleIsInactiveJustPastMaximumAge() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let observation = AssertionObservation(state: .active, sampledAt: now.addingTimeInterval(-35.001))

        XCTAssertFalse(observation.isFreshActive(now: now, maximumAge: 35))
    }

    func testFutureDatedActiveSampleIsInactive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let observation = AssertionObservation(state: .active, sampledAt: now.addingTimeInterval(1))

        XCTAssertFalse(observation.isFreshActive(now: now))
    }

    func testActiveSampleIsInactiveWithNegativeMaximumAge() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let observation = AssertionObservation(state: .active, sampledAt: now)

        XCTAssertFalse(observation.isFreshActive(now: now, maximumAge: -1))
    }

    func testReleaseFailureLeavesPendingObservation() {
        let provider = AssertionProvider(active: true, releaseFails: true)
        let controller = SleepAssertionController(provider: provider)
        controller.enable()
        XCTAssertFalse(controller.release())
        XCTAssertEqual(controller.observation.state, .failed("off-release-pending"))
    }
    func testStatusIconMapsFreshActiveObservationToCheckmark() {
        let now = Date()
        let state = Donts3pStatusIconState(observation: AssertionObservation(state: .active, sampledAt: now), now: now)

        XCTAssertEqual(state.badgeSymbolName, "checkmark.circle.fill")
        XCTAssertEqual(state.accessibilityLabel, "donts3p: sleep prevention active")
    }

    func testStatusIconMapsStaleAndFailedObservationsToX() {
        let now = Date()
        let stale = Donts3pStatusIconState(observation: AssertionObservation(state: .active, sampledAt: now.addingTimeInterval(-36)), now: now)
        let failed = Donts3pStatusIconState(observation: AssertionObservation(state: .failed("create"), sampledAt: now), now: now)

        XCTAssertEqual(stale.badgeSymbolName, "xmark.circle.fill")
        XCTAssertEqual(failed.accessibilityLabel, "donts3p: sleep prevention inactive")
    }
    func testDonts3pLaunchAgentContractUsesFixedCurrentAndLegacyPaths() {
        let home = URL(fileURLWithPath: "/tmp/donts3p-test-home")
        XCTAssertEqual(LaunchAgentContract.appBundleIdentifier, "org.donts3p")
        XCTAssertEqual(LaunchAgentContract.recoveryLabel, "org.donts3p.recovery")
        XCTAssertEqual(LaunchAgentContract.applicationURL.path, "/Applications/donts3p.app")
        XCTAssertEqual(LaunchAgentContract.stateDirectory(homeDirectory: home).path, "/tmp/donts3p-test-home/Library/Application Support/org.donts3p")
        XCTAssertEqual(LaunchAgentContract.legacyRecoveryLabel, "org.dontsleep.recovery")
    }
}

private final class AssertionProvider: SleepAssertionProviding {
    let active: Bool
    let releaseFails: Bool
    init(active: Bool, releaseFails: Bool = false) { self.active = active; self.releaseFails = releaseFails }
    func create() throws -> IOPMAssertionID { 42 }
    func release(_ id: IOPMAssertionID) throws { if releaseFails { throw TestError.failed } }
    func isOwnedAssertionActive(_ id: IOPMAssertionID) throws -> Bool { active }
    enum TestError: Error { case failed }
}
