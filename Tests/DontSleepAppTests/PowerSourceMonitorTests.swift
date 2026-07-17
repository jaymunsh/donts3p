import XCTest
@testable import donts3p

final class PowerSourceMonitorTests: XCTestCase {
    func testBatteryWarningIsDeduplicatedAndACResetsIt() {
        let source = Source(onBattery: true)
        let store = WarningStore()
        let monitor = PowerSourceMonitor(provider: source, store: store, bootID: "boot")
        XCTAssertTrue(monitor.sample())
        XCTAssertFalse(monitor.sample())
        source.state = .AC
        XCTAssertFalse(monitor.sample())
        source.state = .battery
        XCTAssertTrue(monitor.sample())
    }
    func testUnavailablePowerSourcePreservesBatteryWarningLatch() {
        let source = Source(state: .battery)
        let store = WarningStore()
        let monitor = PowerSourceMonitor(provider: source, store: store, bootID: "boot")

        XCTAssertTrue(monitor.sample())
        source.state = .unavailable
        XCTAssertFalse(monitor.sample())
        source.state = .battery
        XCTAssertFalse(monitor.sample())
    }

    func testSameBootSessionDeduplicatesAcrossRelaunches() {
        let store = WarningStore()
        XCTAssertTrue(PowerSourceMonitor(provider: Source(onBattery: true), store: store, bootID: "stable-boot").sample())
        XCTAssertFalse(PowerSourceMonitor(provider: Source(onBattery: true), store: store, bootID: "stable-boot").sample())
        XCTAssertTrue(PowerSourceMonitor(provider: Source(onBattery: true), store: store, bootID: "new-boot").sample())
    }
    func testMissingBootIDDoesNotPersistDeduplication() {
        let source = Source(onBattery: true)
        let store = WarningStore()
        let monitor = PowerSourceMonitor(provider: source, store: store, bootSessionIdentifier: MissingBootID())
        XCTAssertTrue(monitor.bootIDUnavailable)
        XCTAssertTrue(monitor.sample())
        XCTAssertTrue(monitor.sample())
        XCTAssertTrue(store.values.isEmpty)
    }

}
private final class Source: PowerSourceProviding {
    var state: PowerSourceState
    init(onBattery: Bool) { state = onBattery ? .battery : .AC }
    init(state: PowerSourceState) { self.state = state }
    func powerSourceState() -> PowerSourceState { state }
}
private final class WarningStore: BatteryWarningStoring {
    var values: [String: Bool] = [:]
    func warnedOnBattery(bootID: String) -> Bool { values[bootID] ?? false }
    func setWarnedOnBattery(_ warned: Bool, bootID: String) { values[bootID] = warned }
}
private final class MissingBootID: BootSessionIdentifying {
    func bootSessionID() -> String? { nil }
}
