import Foundation

public struct AssertionObservation: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case active
        case inactive
        case failed(String)
    }

    public let state: State
    public let sampledAt: Date

    public init(state: State, sampledAt: Date = Date()) {
        self.state = state
        self.sampledAt = sampledAt
    }

    public func isFreshActive(now: Date = Date(), maximumAge: TimeInterval = 35) -> Bool {
        guard case .active = state, maximumAge >= 0 else { return false }

        let age = now.timeIntervalSince(sampledAt)
        return age >= 0 && age <= maximumAge
    }
}
