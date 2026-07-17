import XCTest
@testable import donts3p

final class SingleInstanceCoordinatorTests: XCTestCase {
    func testSecondNormalLaunchForwardsActivation() {
        let requester = Requester(reply: .enabled)
        let coordinator = SingleInstanceCoordinator(lock: Lock(acquires: false), requester: requester)
        XCTAssertEqual(coordinator.acquire(recovery: false), .forwarded(.enabled))
        XCTAssertTrue(requester.called)
    }

    func testSecondRecoveryLaunchDoesNotForward() {
        let requester = Requester(reply: .enabled)
        let coordinator = SingleInstanceCoordinator(lock: Lock(acquires: false), requester: requester)
        XCTAssertEqual(coordinator.acquire(recovery: true), .recoveryLoser)
        XCTAssertFalse(requester.called)
    }
    func testExpiredDelayedHandlerDoesNotMutateState() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var handlerCalls = 0
        let listener = ActivationListener(homeDirectory: home, requestTimeout: 0.02) {
            handlerCalls += 1
            return .enabled
        }
        XCTAssertTrue(listener.start())
        defer { listener.stop() }

        let requestFinished = expectation(description: "request finished")
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: 0.05)
        }
        DispatchQueue.global().async {
            let reply = UnixSocketActivationRequester(homeDirectory: home).enableAndActivate(timeout: 0.2)
            XCTAssertNil(reply)
            requestFinished.fulfill()
        }

        wait(for: [requestFinished], timeout: 1)
        XCTAssertEqual(handlerCalls, 0)
    }

    func testSocketReplyFramesRoundTripEveryVariant() {
        assertRoundTrip(.enabled)
        assertRoundTrip(.alreadyActive)
        assertRoundTrip(.failed(1))
        assertRoundTrip(.failed(-42))
    }

    private func assertRoundTrip(_ expected: ActivationReply) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let listener = ActivationListener(homeDirectory: home) { expected }
        XCTAssertTrue(listener.start())
        defer { listener.stop() }

        let completed = expectation(description: "round trip \(expected)")
        DispatchQueue.global().async {
            XCTAssertEqual(UnixSocketActivationRequester(homeDirectory: home).enableAndActivate(timeout: 1), expected)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }
}

private final class Lock: InstanceLocking { let acquires: Bool; init(acquires: Bool) { self.acquires = acquires }; func acquire() -> Bool { acquires }; func release() {} }
private final class Requester: ActivationRequesting { let reply: ActivationReply?; var called = false; init(reply: ActivationReply?) { self.reply = reply }; func enableAndActivate(timeout: TimeInterval) -> ActivationReply? { called = true; return reply } }
