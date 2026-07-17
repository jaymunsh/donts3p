import Foundation
import IOKit.pwr_mgt
import DontSleepShared

protocol SleepAssertionProviding {
    func create() throws -> IOPMAssertionID
    func release(_ id: IOPMAssertionID) throws
    func isOwnedAssertionActive(_ id: IOPMAssertionID) throws -> Bool
}

final class IOKitSleepAssertionProvider: SleepAssertionProviding {
    func create() throws -> IOPMAssertionID {
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "donts3p" as CFString,
            &identifier
        )
        guard result == kIOReturnSuccess else { throw SleepAssertionError.ioKit(result) }
        return identifier
    }

    func release(_ id: IOPMAssertionID) throws {
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else { throw SleepAssertionError.ioKit(result) }
    }

    func isOwnedAssertionActive(_ id: IOPMAssertionID) throws -> Bool {
        guard let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [AnyHashable: Any] else {
            return false
        }
        return properties[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep as String
            && (properties[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn)
    }
}

enum SleepAssertionError: Error, Equatable {
    case ioKit(IOReturn)
}

final class SleepAssertionController {
    private let provider: SleepAssertionProviding
    private(set) var assertionID: IOPMAssertionID?
    private(set) var observation = AssertionObservation(state: .inactive)

    init(provider: SleepAssertionProviding = IOKitSleepAssertionProvider()) {
        self.provider = provider
    }

    func enable() {
        guard assertionID == nil else { sample() ; return }
        do {
            assertionID = try provider.create()
            sample()
        } catch {
            observation = AssertionObservation(state: .failed(String(describing: error)))
        }
    }

    func sample(now: Date = Date()) {
        guard let assertionID else {
            observation = AssertionObservation(state: .inactive, sampledAt: now)
            return
        }
        do {
            observation = AssertionObservation(state: try provider.isOwnedAssertionActive(assertionID) ? .active : .failed("assertion-not-observed"), sampledAt: now)
        } catch {
            observation = AssertionObservation(state: .failed(String(describing: error)), sampledAt: now)
        }
    }

    @discardableResult
    func release() -> Bool {
        guard let assertionID else {
            observation = AssertionObservation(state: .inactive)
            return true
        }
        do {
            try provider.release(assertionID)
            self.assertionID = nil
            observation = AssertionObservation(state: .inactive)
            return true
        } catch {
            observation = AssertionObservation(state: .failed("off-release-pending"))
            return false
        }
    }

    func ownedAssertionStillExists() -> Bool {
        guard let assertionID else { return false }
        return (try? provider.isOwnedAssertionActive(assertionID)) ?? true
    }
}
