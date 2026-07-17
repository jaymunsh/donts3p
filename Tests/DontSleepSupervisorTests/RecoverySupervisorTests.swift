import Darwin
import Foundation
import XCTest
@testable import donts3pRecoverySupervisor
import DontSleepShared

final class RecoverySupervisorTests: XCTestCase {
    func testMalformedLeaseIsAnOperationalFailure() {
        let fs = MemoryFileSystem(files: [url("lease"): Data("not-json".utf8)])
        let store = RecoveryLaunchLeaseStore(leaseURL: url("lease"), fileSystem: fs, clock: FixedClock(ticks: 1), bootIdentifier: FixedBootID("boot"))
        XCTAssertThrowsError(try store.activeLease())
    }

    func testStaleLeaseDoesNotSuppressNewLease() throws {
        let fs = MemoryFileSystem(files: [url("lease"): try JSONEncoder().encode(RecoveryLaunchLease(uuid: UUID(), bootID: "boot", machContinuousDeadlineTicks: 100))])
        let store = RecoveryLaunchLeaseStore(leaseURL: url("lease"), fileSystem: fs, clock: FixedClock(ticks: 100), bootIdentifier: FixedBootID("boot"))
        XCTAssertNotNil(try store.acquire(validForTicks: 30))
    }

    func testBootChangeInvalidatesLeaseRegardlessOfDeadline() throws {
        let fs = MemoryFileSystem(files: [url("lease"): try JSONEncoder().encode(RecoveryLaunchLease(uuid: UUID(), bootID: "old", machContinuousDeadlineTicks: UInt64.max))])
        let store = RecoveryLaunchLeaseStore(leaseURL: url("lease"), fileSystem: fs, clock: FixedClock(ticks: 1), bootIdentifier: FixedBootID("new"))
        XCTAssertNil(try store.activeLease())
    }

    func testLeaseUsesContinuousTicksNotWallClock() throws {
        let lease = RecoveryLaunchLease(uuid: UUID(), bootID: "boot", machContinuousDeadlineTicks: 20)
        XCTAssertTrue(lease.isValid(currentBootID: "boot", currentTicks: 19))
        XCTAssertFalse(lease.isValid(currentBootID: "boot", currentTicks: 20))
    }
    func testMalformedLeaseIsPreservedAndReclaimedByNewOwner() throws {
        let leaseURL = url("malformed-reclaim")
        let malformed = Data("not-json".utf8)
        let fs = MemoryFileSystem(files: [leaseURL: malformed])
        let store = RecoveryLaunchLeaseStore(leaseURL: leaseURL, fileSystem: fs, clock: FixedClock(ticks: 1), bootIdentifier: FixedBootID("boot"))

        let lease = try XCTUnwrap(store.acquire(validForTicks: 30))
        XCTAssertEqual(try fs.readData(at: leaseURL.appendingPathExtension("malformed")), malformed)
        XCTAssertEqual(try JSONDecoder().decode(RecoveryLaunchLease.self, from: fs.readData(at: leaseURL)).uuid, lease.uuid)
    }

    func testLeaseRenewalRejectsTokenMismatch() throws {
        let leaseURL = url("renewal")
        let fs = MemoryFileSystem()
        let store = RecoveryLaunchLeaseStore(leaseURL: leaseURL, fileSystem: fs, clock: FixedClock(ticks: 1), bootIdentifier: FixedBootID("boot"))
        let lease = try XCTUnwrap(store.acquire(validForTicks: 30))
        try fs.writeAtomically(try JSONEncoder().encode(RecoveryLaunchLease(uuid: UUID(), bootID: "boot", machContinuousDeadlineTicks: 30)), to: leaseURL)

        XCTAssertThrowsError(try store.renew(lease, validForTicks: 30))
    }

    func testLeaseBudgetCoversRetriesLaunchServicesAndHandoff() {
        XCTAssertEqual(RecoverySupervisor.leaseBudgetSeconds, 86)
    }
    func testResidentMonitorRecoversAfterLaterGUILockLoss() {
        let root = url("later-lock-loss")
        let intentURL = root.appendingPathComponent("intent")
        let fs = MemoryFileSystem(files: [intentURL: Data("enabled".utf8)])
        var waits = 0
        let scheduler = FakeScheduler { _ in
            waits += 1
            if waits == 2 { fs.files[intentURL] = Data("disabled".utf8) }
        }
        let launcher = FakeLauncher(results: [true])
        let runner = makeRunner(
            root: root,
            fs: fs,
            clock: FixedClock(ticks: 1),
            launcher: launcher,
            scheduler: scheduler,
            liveness: SequencedLiveness([true, false, false])
        )

        XCTAssertEqual(runner.run(), .success)
        XCTAssertEqual(launcher.calls, 1)
    }

    func testDuplicateLeaseSuppressesRecovery() throws {
        let root = url("state")
        let fs = MemoryFileSystem(files: [
            root.appendingPathComponent("intent"): Data("enabled\n".utf8),
            root.appendingPathComponent("lease"): try JSONEncoder().encode(RecoveryLaunchLease(uuid: UUID(), bootID: "boot", machContinuousDeadlineTicks: 100))
        ])
        let launcher = FakeLauncher(results: [])
        let runner = makeRunner(root: root, fs: fs, clock: FixedClock(ticks: 1), launcher: launcher)
        XCTAssertEqual(runner.run(), .success)
        XCTAssertEqual(launcher.calls, 0)
    }

    func testFalseIntentExitsSuccessfullyWithoutRecovery() {
        let root = url("false-intent")
        let fs = MemoryFileSystem(files: [root.appendingPathComponent("intent"): Data("disabled".utf8)])
        let launcher = FakeLauncher(results: [])
        XCTAssertEqual(makeRunner(root: root, fs: fs, clock: FixedClock(ticks: 1), launcher: launcher).run(), .success)
        XCTAssertEqual(launcher.calls, 0)
    }

    func testStalePersistentLockFileDoesNotSuppressRecovery() {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: lockURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: lockURL) }
        XCTAssertFalse(AppLivenessMonitor(runLockURL: lockURL, lockProbe: AdvisoryLockProbe()).appIsAlive())
    }

    func testLiveLockSuppressesRecovery() {
        XCTAssertTrue(AppLivenessMonitor(runLockURL: url("live.lock"), lockProbe: FixedLockProbe(true)).appIsAlive())
    }

    func testRecoveryLeaseRemainsAfterOpenBeforeGUIClaimsLock() {
        let root = url("handoff")
        let fs = MemoryFileSystem(files: [root.appendingPathComponent("intent"): Data("enabled".utf8)])
        let runner = makeRunner(root: root, fs: fs, clock: FixedClock(ticks: 1), launcher: FakeLauncher(results: [true]), liveness: FixedLiveness(false))
        XCTAssertEqual(runner.run(), .success)
        XCTAssertTrue(fs.fileExists(at: root.appendingPathComponent("lease")))
    }
    func testAcceptedOpenPollsThroughHandoffWithoutDuplicateLaunchAndClearsLeaseOnLock() {
        let root = url("accepted-open-handoff")
        let intentURL = root.appendingPathComponent("intent")
        let fs = MemoryFileSystem(files: [intentURL: Data("enabled".utf8)])
        var waits = 0
        let scheduler = FakeScheduler { _ in
            waits += 1
            if waits == 5 { fs.files[intentURL] = Data("disabled".utf8) }
        }
        let launcher = FakeLauncher(results: [true])
        let runner = makeRunner(
            root: root,
            fs: fs,
            clock: FixedClock(ticks: 1),
            launcher: launcher,
            scheduler: scheduler,
            liveness: SequencedLiveness([false, false, false, false, true])
        )

        XCTAssertEqual(runner.run(), .success)
        XCTAssertEqual(launcher.calls, 1)
        XCTAssertFalse(fs.fileExists(at: root.appendingPathComponent("lease")))
    }


    func testSimultaneousLeaseAcquisitionHasOneWinner() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let leaseURL = root.appendingPathComponent("lease")
        let first = RecoveryLaunchLeaseStore(leaseURL: leaseURL, fileSystem: LocalSupervisorFileSystem(), clock: FixedClock(ticks: 1), bootIdentifier: FixedBootID("boot"))
        let second = RecoveryLaunchLeaseStore(leaseURL: leaseURL, fileSystem: LocalSupervisorFileSystem(), clock: FixedClock(ticks: 1), bootIdentifier: FixedBootID("boot"))
        let resultLock = NSLock()
        var winners = 0
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let store = index == 0 ? first : second
            if (try? store.acquire(validForTicks: 30)) != nil {
                resultLock.lock()
                winners += 1
                resultLock.unlock()
            }
        }
        XCTAssertEqual(winners, 1)
    }

    func testLaunchServicesTimeoutIsTypedAndLateCallbackDoesNotSucceed() {
        let applicationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: applicationURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: applicationURL) }
        let launcher = LaunchServicesRecoveryLauncher(applicationURL: applicationURL, opener: DelayedOpener(), timeout: .milliseconds(1))
        XCTAssertThrowsError(try launcher.launchRecovery()) { error in
            guard case RecoveryLaunchError.completionTimedOut = error else {
                return XCTFail("Expected a LaunchServices completion timeout, got \(error)")
            }
        }
    }

    func testRecoveryAttemptsAreBoundedAndPersistDegradedState() {
        let root = url("bounded")
        let fs = MemoryFileSystem(files: [root.appendingPathComponent("intent"): Data("enabled".utf8)])
        let launcher = FakeLauncher(results: [false, false, false, false, false])
        var waits = 0
        let scheduler = FakeScheduler { _ in
            waits += 1
            if waits == 5 {
                fs.files[root.appendingPathComponent("intent")] = Data("disabled".utf8)
            }
        }
        let runner = makeRunner(root: root, fs: fs, clock: FixedClock(ticks: 1), launcher: launcher, scheduler: scheduler)
        XCTAssertEqual(runner.run(), .success)
        XCTAssertEqual(launcher.calls, 4)
        XCTAssertEqual(scheduler.delays, [1, 5, 30, 1, 1])
        let degraded = try JSONDecoder().decode(DegradedState.self, from: fs.readData(at: root.appendingPathComponent("degraded")))
        XCTAssertTrue(degraded.lastLaunchFailureType.contains("LaunchFailure"))
        XCTAssertEqual(degraded.attemptCount, 4)
        XCTAssertEqual(degraded.bootID, "boot")
        XCTAssertEqual(degraded.machContinuousTicks, 1)
        XCTAssertFalse(degraded.lastLaunchFailureTimestamp.isEmpty)
    }
    func testPersistedDegradedStateSuppressesLaunches() {
        let root = url("persisted-degraded")
        let intentURL = root.appendingPathComponent("intent")
        let fs = MemoryFileSystem(files: [
            intentURL: Data("enabled".utf8),
            root.appendingPathComponent("degraded"): Data("previous failure".utf8)
        ])
        let scheduler = FakeScheduler { _ in
            fs.files[intentURL] = Data("disabled".utf8)
        }
        let launcher = FakeLauncher(results: [true])

        XCTAssertEqual(makeRunner(root: root, fs: fs, clock: FixedClock(ticks: 1), launcher: launcher, scheduler: scheduler).run(), .success)
        XCTAssertEqual(launcher.calls, 0)
    }


    func testDurableWriteSynchronizesFileBeforeRenameAndDirectoryAfterward() throws {
        let operations = RecordingDurableFileOperations()
        try DurableAtomicFileWriter(operations: operations).write(Data("lease".utf8), to: url("durable/lease"))

        XCTAssertEqual(operations.events, ["createDirectory", "createTemporaryFile:384", "write", "fsyncFile", "close", "rename", "fsyncDirectory"])
    }

    func testDurableWriteDoesNotRenameWhenFileSyncFails() {
        let operations = RecordingDurableFileOperations(failOnFileSync: true)

        XCTAssertThrowsError(try DurableAtomicFileWriter(operations: operations).write(Data("lease".utf8), to: url("durable/lease")))
        XCTAssertEqual(operations.events, ["createDirectory", "createTemporaryFile:384", "write", "fsyncFile", "close", "removeTemporary"])
    }

    private func makeRunner(root: URL, fs: MemoryFileSystem, clock: FixedClock, launcher: FakeLauncher, scheduler: FakeScheduler? = nil, liveness: AppLivenessMonitoring = FixedLiveness(false)) -> RecoverySupervisor {
        let scheduler = scheduler ?? FakeScheduler { _ in
            fs.files[root.appendingPathComponent("intent")] = Data("disabled".utf8)
        }
        return RecoverySupervisor(
            intentStore: IntentMarkerStore(markerURL: root.appendingPathComponent("intent"), fileSystem: fs),
            livenessMonitor: liveness,
            leaseStore: RecoveryLaunchLeaseStore(leaseURL: root.appendingPathComponent("lease"), fileSystem: fs, clock: clock, bootIdentifier: FixedBootID("boot")),
            launcher: launcher,
            scheduler: scheduler,
            fileSystem: fs,
            degradedStateURL: root.appendingPathComponent("degraded"),
            leaseDurationTicks: 30
        )
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/dontsleep-tests/\(name)") }
}

private struct DegradedState: Decodable {
    let lastLaunchFailureType: String
    let lastLaunchFailureTimestamp: String
    let attemptCount: Int
    let bootID: String
    let machContinuousTicks: UInt64
}
private struct FixedClock: RecoveryClock { let ticks: UInt64; func continuousTimeTicks() -> UInt64 { ticks } }
private struct FixedBootID: BootIdentifying { let value: String; init(_ value: String) { self.value = value }; func bootIdentifier() throws -> String { value } }
private struct FixedLockProbe: AdvisoryLockProbing { let held: Bool; init(_ held: Bool) { self.held = held }; func lockIsHeld(at url: URL) -> Bool { held } }
private struct FixedLiveness: AppLivenessMonitoring { let alive: Bool; init(_ alive: Bool) { self.alive = alive }; func appIsAlive() -> Bool { alive } }
private final class SequencedLiveness: AppLivenessMonitoring {
    private var values: [Bool]
    init(_ values: [Bool]) { self.values = values }
    func appIsAlive() -> Bool { values.isEmpty ? false : values.removeFirst() }
}
private final class DelayedOpener: RecoveryApplicationOpening {
    func openApplication(at url: URL, arguments: [String], completion: @escaping (Error?) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) {
            completion(nil)
        }
    }
}
private enum LaunchFailure: Error { case failed }
private final class FakeLauncher: RecoveryLaunching {
    private var results: [Bool]
    private(set) var calls = 0
    init(results: [Bool]) { self.results = results }
    func launchRecovery() throws { calls += 1; if results.isEmpty || !results.removeFirst() { throw LaunchFailure.failed } }
}
private final class FakeScheduler: RecoveryAttemptScheduling {
    private(set) var delays: [TimeInterval] = []
    private let onWait: (TimeInterval) -> Void

    init(onWait: @escaping (TimeInterval) -> Void = { _ in }) {
        self.onWait = onWait
    }

    func wait(seconds: TimeInterval) {
        delays.append(seconds)
        onWait(seconds)
    }
}
private final class MemoryFileSystem: SupervisorFileSystem {
    var files: [URL: Data]
    init(files: [URL: Data] = [:]) { self.files = files }
    func fileExists(at url: URL) -> Bool { files[url] != nil }
    func readData(at url: URL) throws -> Data { guard let data = files[url] else { throw CocoaError(.fileNoSuchFile) }; return data }
    func writeAtomically(_ data: Data, to url: URL) throws { files[url] = data }
    func removeItem(at url: URL) throws { files.removeValue(forKey: url) }
    func createDirectory(at url: URL) throws {}
}
private enum DurableWriteFailure: Error { case fileSync }

private final class RecordingDurableFileOperations: DurableFileOperations {
    private(set) var events: [String] = []
    private let failOnFileSync: Bool

    init(failOnFileSync: Bool = false) {
        self.failOnFileSync = failOnFileSync
    }

    func createDirectory(at url: URL) throws { events.append("createDirectory") }
    func createTemporaryFile(at url: URL, permissions: mode_t) throws -> Int32 {
        events.append("createTemporaryFile:\(permissions)")
        return 42
    }
    func write(_ data: Data, to descriptor: Int32) throws { events.append("write") }
    func synchronizeFile(descriptor: Int32) throws {
        events.append("fsyncFile")
        if failOnFileSync { throw DurableWriteFailure.fileSync }
    }
    func closeFile(descriptor: Int32) { events.append("close") }
    func renameItem(from source: URL, to destination: URL) throws { events.append("rename") }
    func synchronizeDirectory(at url: URL) throws { events.append("fsyncDirectory") }
    func removeItem(at url: URL) { events.append("removeTemporary") }
}
