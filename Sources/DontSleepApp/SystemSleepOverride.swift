import Foundation

struct SystemSleepOverrideSnapshot: Codable, Equatable {
    let batteryPower: Int?
    let acPower: Int?
    let upsPower: Int?

    init(batteryPower: Int? = nil, acPower: Int? = nil, upsPower: Int? = nil) throws {
        let values = [batteryPower, acPower, upsPower]
        guard values.contains(where: { $0 != nil }) else {
            throw SystemSleepOverrideError.priorValueUnavailable
        }
        for value in values {
            guard let value else { continue }
            guard value == 0 || value == 1 else {
                throw SystemSleepOverrideError.priorValueUnavailable
            }
        }
        self.batteryPower = batteryPower
        self.acPower = acPower
        self.upsPower = upsPower
    }

    private enum CodingKeys: String, CodingKey {
        case batteryPower
        case acPower
        case upsPower
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            batteryPower: container.decodeIfPresent(Int.self, forKey: .batteryPower),
            acPower: container.decodeIfPresent(Int.self, forKey: .acPower),
            upsPower: container.decodeIfPresent(Int.self, forKey: .upsPower)
        )
    }
}

enum SystemSleepOverrideObservedState: Equatable {
    case off
    case enabled
    case mixed
    case unknown
}

enum SystemSleepOverrideError: LocalizedError, Equatable {
    case notOnACPower
    case priorValueUnavailable
    case verificationFailed(expected: SystemSleepOverrideSnapshot, actual: SystemSleepOverrideSnapshot?)
    case commandFailed(String)
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .notOnACPower: return "System sleep override can only be enabled while connected to AC power."
        case .priorValueUnavailable: return "Unable to read the current system sleep setting."
        case let .verificationFailed(expected, actual): return "System sleep override verification failed: expected \(expected), found \(actual.map { String(describing: $0) } ?? "no value")."
        case let .commandFailed(message): return "The administrator command failed: \(message)"
        case let .persistenceFailed(message): return "Unable to save the prior system sleep setting: \(message)"
        }
    }
}

struct SystemCommandResult {
    let status: Int32
    let output: String
}

protocol SystemCommandRunning {
    func run(executable: String, arguments: [String]) -> SystemCommandResult
}

struct ProcessSystemCommandRunner: SystemCommandRunning {
    func run(executable: String, arguments: [String]) -> SystemCommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            return SystemCommandResult(status: process.terminationStatus, output: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        } catch {
            return SystemCommandResult(status: -1, output: error.localizedDescription)
        }
    }
}

protocol SystemSleepOverrideStoring: AnyObject {
    func savedSnapshot() throws -> SystemSleepOverrideSnapshot?
    func saveSnapshot(_ snapshot: SystemSleepOverrideSnapshot) throws
    func removeSavedSnapshot() throws
}

final class ApplicationSupportSystemSleepOverrideStore: SystemSleepOverrideStoring {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        fileURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/org.donts3p", isDirectory: true)
            .appendingPathComponent("system-sleep-override.json")
    }

    func savedSnapshot() throws -> SystemSleepOverrideSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(SystemSleepOverrideSnapshot.self, from: Data(contentsOf: fileURL))
    }

    func saveSnapshot(_ snapshot: SystemSleepOverrideSnapshot) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    func removeSavedSnapshot() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

protocol SystemSleepOverrideControlling: AnyObject {
    var isEnabled: Bool { get }
    var observedState: SystemSleepOverrideObservedState { get }
    var hasPendingRestore: Bool { get }
    var diagnostic: String? { get }
    func refresh()
    func enable() throws
    func restore() throws
}

final class SystemSleepOverrideController: SystemSleepOverrideControlling {
    private let runner: SystemCommandRunning
    private let store: SystemSleepOverrideStoring
    private let powerSourceProvider: PowerSourceProviding
    private(set) var isEnabled = false
    private(set) var observedState: SystemSleepOverrideObservedState = .unknown
    private(set) var hasPendingRestore = false
    private(set) var diagnostic: String?
    private var snapshotReadError: Error?

    init(runner: SystemCommandRunning = ProcessSystemCommandRunner(), store: SystemSleepOverrideStoring = ApplicationSupportSystemSleepOverrideStore(), powerSourceProvider: PowerSourceProviding = IOKitPowerSourceProvider()) {
        self.runner = runner
        self.store = store
        self.powerSourceProvider = powerSourceProvider
        refresh()
    }

    static func disablesleepSnapshot(in output: String) -> SystemSleepOverrideSnapshot? {
        enum Profile {
            case battery, ac, ups
        }

        var currentProfile: Profile?
        var batteryPower: Int?
        var acPower: Int?
        var upsPower: Int?
        var sawBattery = false
        var sawAC = false
        var sawUPS = false

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmedLine {
            case "Battery Power:": currentProfile = .battery; sawBattery = true
            case "AC Power:": currentProfile = .ac; sawAC = true
            case "UPS Power:": currentProfile = .ups; sawUPS = true
            default:
                if trimmedLine.hasSuffix(":") {
                    currentProfile = nil
                    continue
                }
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard let currentProfile, fields.first == "disablesleep" else { continue }
                guard fields.count == 2, let value = Int(fields[1]), value == 0 || value == 1 else { return nil }
                switch currentProfile {
                case .battery: batteryPower = value
                case .ac: acPower = value
                case .ups: upsPower = value
                }
            }
        }

        if sawBattery, batteryPower == nil { batteryPower = 0 }
        if sawAC, acPower == nil { acPower = 0 }
        if sawUPS, upsPower == nil { upsPower = 0 }
        return try? SystemSleepOverrideSnapshot(batteryPower: batteryPower, acPower: acPower, upsPower: upsPower)
    }

    func refresh() {
        do {
            hasPendingRestore = try store.savedSnapshot() != nil
            snapshotReadError = nil
        } catch {
            hasPendingRestore = false
            snapshotReadError = error
        }

        let result = runner.run(executable: "/usr/bin/pmset", arguments: ["-g", "custom"])
        if result.status != 0 {
            observedState = .unknown
            isEnabled = false
            diagnostic = SystemSleepOverrideError.commandFailed(result.output).localizedDescription
        } else if let snapshot = Self.disablesleepSnapshot(in: result.output) {
            let values = [snapshot.batteryPower, snapshot.acPower, snapshot.upsPower].compactMap { $0 }
            if values.allSatisfy({ $0 == 0 }) {
                observedState = .off
            } else if values.allSatisfy({ $0 == 1 }) {
                observedState = .enabled
            } else {
                observedState = .mixed
            }
            isEnabled = observedState == .enabled
            diagnostic = nil
        } else {
            observedState = .unknown
            isEnabled = false
            diagnostic = SystemSleepOverrideError.priorValueUnavailable.localizedDescription
        }

        if let snapshotReadError {
            diagnostic = "Saved recovery snapshot is unreadable. Do not enable the override. Restore manually with: sudo /usr/bin/pmset -a disablesleep 0. (\(snapshotReadError.localizedDescription))"
        }
    }

    func enable() throws {
        guard snapshotReadError == nil else {
            throw SystemSleepOverrideError.persistenceFailed("Saved recovery snapshot is unreadable. Restore manually with: sudo /usr/bin/pmset -a disablesleep 0.")
        }
        guard powerSourceProvider.powerSourceState() == .AC else { throw SystemSleepOverrideError.notOnACPower }
        let prior = try readSnapshot()
        guard try store.savedSnapshot() == nil else { throw SystemSleepOverrideError.commandFailed("A previous override must be restored before enabling again.") }
        do { try store.saveSnapshot(prior) } catch { throw SystemSleepOverrideError.persistenceFailed(error.localizedDescription) }
        hasPendingRestore = true
        guard powerSourceProvider.powerSourceState() == .AC else { throw SystemSleepOverrideError.notOnACPower }
        try privilegedSetAll(value: 1)
        try verify(SystemSleepOverrideSnapshot(batteryPower: prior.batteryPower.map { _ in 1 }, acPower: prior.acPower.map { _ in 1 }, upsPower: prior.upsPower.map { _ in 1 }))
        observedState = .enabled
        isEnabled = true
        diagnostic = nil
    }

    func restore() throws {
        guard let prior = try store.savedSnapshot() else { throw SystemSleepOverrideError.priorValueUnavailable }
        try privilegedRestore(prior)
        try verify(prior)
        do { try store.removeSavedSnapshot() } catch { throw SystemSleepOverrideError.persistenceFailed(error.localizedDescription) }
        hasPendingRestore = false
        let values = [prior.batteryPower, prior.acPower, prior.upsPower].compactMap { $0 }
        observedState = values.allSatisfy { $0 == 0 } ? .off : (values.allSatisfy { $0 == 1 } ? .enabled : .mixed)
        isEnabled = observedState == .enabled
        diagnostic = nil
    }

    private func readSnapshot() throws -> SystemSleepOverrideSnapshot {
        let result = runner.run(executable: "/usr/bin/pmset", arguments: ["-g", "custom"])
        guard result.status == 0 else { throw SystemSleepOverrideError.commandFailed(result.output) }
        guard let snapshot = Self.disablesleepSnapshot(in: result.output) else { throw SystemSleepOverrideError.priorValueUnavailable }
        return snapshot
    }

    private func privilegedSetAll(value: Int) throws {
        guard value == 1 else { throw SystemSleepOverrideError.priorValueUnavailable }
        try runPrivileged(command: "if /usr/bin/pmset -g batt | /usr/bin/grep -q 'AC Power'; then /usr/bin/pmset -a disablesleep 1; else exit 1; fi")
    }

    private func privilegedRestore(_ snapshot: SystemSleepOverrideSnapshot) throws {
        var commands: [String] = []
        if let value = snapshot.batteryPower { commands.append("/usr/bin/pmset -b disablesleep \(value)") }
        if let value = snapshot.acPower { commands.append("/usr/bin/pmset -c disablesleep \(value)") }
        if let value = snapshot.upsPower { commands.append("/usr/bin/pmset -u disablesleep \(value)") }
        guard !commands.isEmpty else { throw SystemSleepOverrideError.priorValueUnavailable }
        try runPrivileged(command: commands.joined(separator: "; "))
    }

    private func runPrivileged(command: String) throws {
        let script = "do shell script \"\(command)\" with administrator privileges"
        let result = runner.run(executable: "/usr/bin/osascript", arguments: ["-e", script])
        guard result.status == 0 else { throw SystemSleepOverrideError.commandFailed(result.output) }
    }

    private func verify(_ expected: SystemSleepOverrideSnapshot) throws {
        let actual = try readSnapshot()
        guard actual == expected else { throw SystemSleepOverrideError.verificationFailed(expected: expected, actual: actual) }
    }
}
