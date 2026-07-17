import Foundation
import Darwin
import IOKit.ps

enum PowerSourceState {
    case battery
    case AC
    case unavailable
}

protocol PowerSourceProviding {
    func powerSourceState() -> PowerSourceState
}

struct IOKitPowerSourceProvider: PowerSourceProviding {
    func powerSourceState() -> PowerSourceState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return .unavailable }

        var observedAC = false
        for source in sources {
            guard let details = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let state = details[kIOPSPowerSourceStateKey] as? String else { return .unavailable }
            if state == kIOPSBatteryPowerValue { return .battery }
            observedAC = true
        }
        return observedAC ? .AC : .unavailable
    }
}

protocol BootSessionIdentifying {
    func bootSessionID() -> String?
}

struct SystemBootSessionIdentifier: BootSessionIdentifying {
    func bootSessionID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}

protocol BatteryWarningStoring: AnyObject {
    func warnedOnBattery(bootID: String) -> Bool
    func setWarnedOnBattery(_ warned: Bool, bootID: String)
}

final class UserDefaultsBatteryWarningStore: BatteryWarningStoring {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func warnedOnBattery(bootID: String) -> Bool { defaults.string(forKey: "batteryWarning.bootID") == bootID && defaults.bool(forKey: "batteryWarning.warned") }
    func setWarnedOnBattery(_ warned: Bool, bootID: String) {
        defaults.set(bootID, forKey: "batteryWarning.bootID")
        defaults.set(warned, forKey: "batteryWarning.warned")
    }
}

final class PowerSourceMonitor {
    private let provider: PowerSourceProviding
    private let store: BatteryWarningStoring
    private let bootID: String?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var changeHandler: (() -> Void)?

    var bootIDUnavailable: Bool { bootID == nil }

    init(provider: PowerSourceProviding = IOKitPowerSourceProvider(), store: BatteryWarningStoring = UserDefaultsBatteryWarningStore(), bootID: String? = nil, bootSessionIdentifier: BootSessionIdentifying = SystemBootSessionIdentifier()) {
        self.provider = provider
        self.store = store
        self.bootID = bootID ?? bootSessionIdentifier.bootSessionID()
    }

    deinit { stopObserving() }

    func startObserving(_ handler: @escaping () -> Void) {
        guard powerSourceRunLoopSource == nil else { return }
        changeHandler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { monitor.changeHandler?() }
        }, context)?.takeRetainedValue() else { return }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stopObserving() {
        guard let source = powerSourceRunLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = nil
        changeHandler = nil
    }

    /// Returns true exactly once per boot after a battery observation; only actual AC resets the latch.
    func sample() -> Bool {
        switch provider.powerSourceState() {
        case .battery:
            guard let bootID else { return true }
            guard !store.warnedOnBattery(bootID: bootID) else { return false }
            store.setWarnedOnBattery(true, bootID: bootID)
            return true
        case .AC:
            guard let bootID else { return false }
            store.setWarnedOnBattery(false, bootID: bootID)
            return false
        case .unavailable:
            return false
        }
    }
}
