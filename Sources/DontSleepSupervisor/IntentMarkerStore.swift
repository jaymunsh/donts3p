import Darwin
import Foundation
import DontSleepShared

protocol SupervisorFileSystem {
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
    func createDirectory(at url: URL) throws
}
protocol DurableFileOperations {
    func createDirectory(at url: URL) throws
    func createTemporaryFile(at url: URL, permissions: mode_t) throws -> Int32
    func write(_ data: Data, to descriptor: Int32) throws
    func synchronizeFile(descriptor: Int32) throws
    func closeFile(descriptor: Int32)
    func renameItem(from source: URL, to destination: URL) throws
    func synchronizeDirectory(at url: URL) throws
    func removeItem(at url: URL)
}

struct POSIXDurableFileOperations: DurableFileOperations {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func createTemporaryFile(at url: URL, permissions: mode_t) throws -> Int32 {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, permissions)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }

    func synchronizeFile(descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func closeFile(descriptor: Int32) {
        _ = close(descriptor)
    }

    func renameItem(from source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func removeItem(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

struct DurableAtomicFileWriter {
    let operations: DurableFileOperations

    init(operations: DurableFileOperations = POSIXDurableFileOperations()) {
        self.operations = operations
    }

    func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try operations.createDirectory(at: directory)
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        var descriptor: Int32? = try operations.createTemporaryFile(at: temporaryURL, permissions: S_IRUSR | S_IWUSR)
        do {
            try operations.write(data, to: descriptor!)
            try operations.synchronizeFile(descriptor: descriptor!)
            operations.closeFile(descriptor: descriptor!)
            descriptor = nil
            try operations.renameItem(from: temporaryURL, to: url)
            try operations.synchronizeDirectory(at: directory)
        } catch {
            if let descriptor {
                operations.closeFile(descriptor: descriptor)
            }
            operations.removeItem(at: temporaryURL)
            throw error
        }
    }
}

struct LocalSupervisorFileSystem: SupervisorFileSystem {
    private let manager: FileManager
    private let durableWriter: DurableAtomicFileWriter

    init(manager: FileManager = .default, durableWriter: DurableAtomicFileWriter = DurableAtomicFileWriter()) {
        self.manager = manager
        self.durableWriter = durableWriter
    }

    func fileExists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try durableWriter.write(data, to: url)
    }

    func removeItem(at url: URL) throws {
        guard fileExists(at: url) else { return }
        try manager.removeItem(at: url)
    }

    func createDirectory(at url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

struct IntentMarkerStore {
    let fileSystem: SupervisorFileSystem
    let markerURL: URL

    init(homeDirectory: URL, fileSystem: SupervisorFileSystem = LocalSupervisorFileSystem()) {
        self.fileSystem = fileSystem
        self.markerURL = LaunchAgentContract.intentMarkerURL(homeDirectory: homeDirectory)
    }

    init(markerURL: URL, fileSystem: SupervisorFileSystem) {
        self.markerURL = markerURL
        self.fileSystem = fileSystem
    }

    /// An enabled marker must contain exactly the explicit, durable intent token.
    func recoveryIsEnabled() throws -> Bool {
        guard fileSystem.fileExists(at: markerURL) else { return false }
        let data = try fileSystem.readData(at: markerURL)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "enabled"
    }
}
