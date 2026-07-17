import Foundation
import Darwin
import DontSleepShared

protocol RecoveryClock {
    func continuousTimeTicks() -> UInt64
}

struct SystemRecoveryClock: RecoveryClock {
    func continuousTimeTicks() -> UInt64 {
        mach_continuous_time()
    }
}

protocol BootIdentifying {
    func bootIdentifier() throws -> String
}

enum BootIdentifierError: Error {
    case unavailable
}

struct SystemBootIdentifier: BootIdentifying {
    func bootIdentifier() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            throw BootIdentifierError.unavailable
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            throw BootIdentifierError.unavailable
        }
        return String(cString: bytes)
    }
}

struct RecoveryLaunchLease: Codable, Equatable {
    let uuid: UUID
    let bootID: String
    let machContinuousDeadlineTicks: UInt64

    func isValid(currentBootID: String, currentTicks: UInt64) -> Bool {
        bootID == currentBootID && machContinuousDeadlineTicks > currentTicks
    }
}

enum RecoveryLeaseError: Error {
    case malformed
    case ownershipLost
    case lockUnavailable
}

protocol RecoveryLeaseLocking {
    func withExclusiveAccess<T>(to leaseURL: URL, _ body: () throws -> T) throws -> T
}

struct FileRecoveryLeaseLock: RecoveryLeaseLocking {
    func withExclusiveAccess<T>(to leaseURL: URL, _ body: () throws -> T) throws -> T {
        let lockURL = leaseURL.appendingPathExtension("lock")
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RecoveryLeaseError.lockUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw RecoveryLeaseError.lockUnavailable }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}

struct RecoveryLaunchLeaseStore {
    let fileSystem: SupervisorFileSystem
    let leaseURL: URL
    let clock: RecoveryClock
    let bootIdentifier: BootIdentifying
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let locker: RecoveryLeaseLocking

    init(
        homeDirectory: URL,
        fileSystem: SupervisorFileSystem = LocalSupervisorFileSystem(),
        clock: RecoveryClock = SystemRecoveryClock(),
        bootIdentifier: BootIdentifying = SystemBootIdentifier(),
        locker: RecoveryLeaseLocking = FileRecoveryLeaseLock()
    ) {
        self.init(
            leaseURL: LaunchAgentContract.recoveryLeaseURL(homeDirectory: homeDirectory),
            fileSystem: fileSystem,
            clock: clock,
            bootIdentifier: bootIdentifier,
            locker: locker
        )
    }

    init(leaseURL: URL, fileSystem: SupervisorFileSystem, clock: RecoveryClock, bootIdentifier: BootIdentifying, encoder: JSONEncoder = JSONEncoder(), decoder: JSONDecoder = JSONDecoder(), locker: RecoveryLeaseLocking = FileRecoveryLeaseLock()) {
        self.leaseURL = leaseURL
        self.fileSystem = fileSystem
        self.clock = clock
        self.bootIdentifier = bootIdentifier
        self.encoder = encoder
        self.decoder = decoder
        self.locker = locker
    }

    func activeLease() throws -> RecoveryLaunchLease? {
        guard fileSystem.fileExists(at: leaseURL) else { return nil }
        let lease: RecoveryLaunchLease
        do {
            lease = try decoder.decode(RecoveryLaunchLease.self, from: fileSystem.readData(at: leaseURL))
        } catch {
            throw RecoveryLeaseError.malformed
        }
        return lease.isValid(currentBootID: try bootIdentifier.bootIdentifier(), currentTicks: clock.continuousTimeTicks()) ? lease : nil
    }

    @discardableResult
    func acquire(validForTicks: UInt64) throws -> RecoveryLaunchLease? {
        try locker.withExclusiveAccess(to: leaseURL) {
            do {
                guard try activeLease() == nil else { return nil }
            } catch RecoveryLeaseError.malformed {
                try fileSystem.writeAtomically(
                    try fileSystem.readData(at: leaseURL),
                    to: leaseURL.appendingPathExtension("malformed")
                )
            }

            let lease = try newLease(validForTicks: validForTicks)
            try fileSystem.writeAtomically(try encoder.encode(lease), to: leaseURL)
            let persisted = try decoder.decode(RecoveryLaunchLease.self, from: fileSystem.readData(at: leaseURL))
            guard persisted.uuid == lease.uuid else { throw RecoveryLeaseError.ownershipLost }
            return lease
        }
    }

    func renew(_ lease: RecoveryLaunchLease, validForTicks: UInt64) throws -> RecoveryLaunchLease {
        try locker.withExclusiveAccess(to: leaseURL) {
            let persisted: RecoveryLaunchLease
            do {
                persisted = try decoder.decode(RecoveryLaunchLease.self, from: fileSystem.readData(at: leaseURL))
            } catch {
                throw RecoveryLeaseError.ownershipLost
            }
            let currentBootID = try bootIdentifier.bootIdentifier()
            guard persisted.uuid == lease.uuid, persisted.bootID == currentBootID else {
                throw RecoveryLeaseError.ownershipLost
            }
            let renewed = try newLease(uuid: lease.uuid, validForTicks: validForTicks)
            try fileSystem.writeAtomically(try encoder.encode(renewed), to: leaseURL)
            let verified = try decoder.decode(RecoveryLaunchLease.self, from: fileSystem.readData(at: leaseURL))
            guard verified == renewed else { throw RecoveryLeaseError.ownershipLost }
            return renewed
        }
    }

    private func newLease(uuid: UUID = UUID(), validForTicks: UInt64) throws -> RecoveryLaunchLease {
        let now = clock.continuousTimeTicks()
        let (deadline, overflow) = now.addingReportingOverflow(validForTicks)
        guard !overflow else { throw RecoveryLeaseError.malformed }
        return RecoveryLaunchLease(
            uuid: uuid,
            bootID: try bootIdentifier.bootIdentifier(),
            machContinuousDeadlineTicks: deadline
        )
    }

    func clear(_ lease: RecoveryLaunchLease) throws {
        try locker.withExclusiveAccess(to: leaseURL) {
            guard fileSystem.fileExists(at: leaseURL) else { return }
            let persisted: RecoveryLaunchLease
            do {
                persisted = try decoder.decode(RecoveryLaunchLease.self, from: fileSystem.readData(at: leaseURL))
            } catch {
                throw RecoveryLeaseError.malformed
            }
            guard persisted.uuid == lease.uuid else { throw RecoveryLeaseError.ownershipLost }
            try fileSystem.removeItem(at: leaseURL)
        }
    }
}
