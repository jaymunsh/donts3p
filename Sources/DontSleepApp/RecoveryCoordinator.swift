import Darwin
import Foundation
import ServiceManagement
import DontSleepShared

protocol RecoveryManaging {
    func enableRecovery() throws
    func disableRecovery() throws
}

enum RecoveryManagerError: Error {
    case serviceNotEnabled(rollbackError: Error?)
    case markerWrite(primary: Error, rollbackError: Error?)
}

/// Owns the unprivileged launch-agent and marker transaction. The marker is
/// durably published before launchd can start the recovery supervisor.
final class RecoveryManager: RecoveryManaging {
    private let markerURL: URL
    private let degradedStateURL: URL
    private let legacyMarkerURL: URL
    private let service: SMAppService
    private let legacyService: SMAppService
    private let fileManager: FileManager

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         fileManager: FileManager = .default,
         service: SMAppService = .agent(plistName: "org.donts3p.recovery.plist"),
         legacyService: SMAppService = .agent(plistName: "org.dontsleep.recovery.plist")) {
        self.markerURL = LaunchAgentContract.intentMarkerURL(homeDirectory: homeDirectory)
        self.degradedStateURL = LaunchAgentContract.recoveryDegradedURL(homeDirectory: homeDirectory)
        self.legacyMarkerURL = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(LaunchAgentContract.legacyStateDirectoryName, isDirectory: true)
            .appendingPathComponent("recovery.enabled")
        self.fileManager = fileManager
        self.service = service
        self.legacyService = legacyService
    }

    func enableRecovery() throws {
        try deactivateLegacyRecovery()
        try writeMarker()

        do {
            if service.status == .enabled {
                try service.unregister()
                guard service.status != .enabled else {
                    throw RecoveryManagerError.serviceNotEnabled(rollbackError: nil)
                }
            }
            try service.register()
            guard service.status == .enabled else {
                throw RecoveryManagerError.serviceNotEnabled(rollbackError: nil)
            }
        } catch {
            let primary = error
            do {
                try fileManager.removeItem(at: markerURL)
                throw RecoveryManagerError.markerWrite(primary: primary, rollbackError: nil)
            } catch let error as RecoveryManagerError {
                throw error
            } catch {
                throw RecoveryManagerError.markerWrite(primary: primary, rollbackError: error)
            }
        }
    }

    private func writeMarker() throws {
        let directory = markerURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let temporaryURL = directory.appendingPathComponent(".\(markerURL.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer {
            _ = close(descriptor)
            try? fileManager.removeItem(at: temporaryURL)
        }

        let data = Array("enabled\n".utf8)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            guard written > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard rename(temporaryURL.path, markerURL.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let directoryDescriptor = open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
    private func deactivateLegacyRecovery() throws {
        if legacyService.status == .enabled {
            try legacyService.unregister()
            guard legacyService.status != .enabled else {
                throw RecoveryManagerError.serviceNotEnabled(rollbackError: nil)
            }
        }
        if fileManager.fileExists(atPath: legacyMarkerURL.path) {
            try fileManager.removeItem(at: legacyMarkerURL)
        }
    }


    func disableRecovery() throws {
        // Do not touch the supervisor lease: an active supervisor owns it and will
        // observe the marker removal before releasing it.
        if fileManager.fileExists(atPath: markerURL.path) {
            try fileManager.removeItem(at: markerURL)
        }
        if service.status == .enabled {
            try service.unregister()
        }
        if fileManager.fileExists(atPath: degradedStateURL.path) {
            try fileManager.removeItem(at: degradedStateURL)
        }
        try deactivateLegacyRecovery()
    }

    static func isRecoveryLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(LaunchAgentContract.recoveryArgument)
    }
}
