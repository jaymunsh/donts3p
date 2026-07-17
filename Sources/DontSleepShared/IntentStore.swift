import Foundation

// Both the GUI and recovery supervisor use this durable, per-user desired state.
public protocol IntentStoring: AnyObject {
    func desiredActive() throws -> Bool
    /// `nil` distinguishes a first launch from an explicit disabled intent.
    func storedDesiredActive() throws -> Bool?
    func setDesiredActive(_ active: Bool) throws
}
public extension IntentStoring {
    func storedDesiredActive() throws -> Bool? { try desiredActive() }
}


public final class IntentStore: IntentStoring {
    private let url: URL
    private let fileManager: FileManager

    public init(applicationSupportDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = applicationSupportDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = base.appendingPathComponent("org.donts3p", isDirectory: true).appendingPathComponent("intent.json")
    }

    public func desiredActive() throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Intent.self, from: data).desiredActive
    }
    public func storedDesiredActive() throws -> Bool? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try desiredActive()
    }

    public func setDesiredActive(_ active: Bool) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Intent(desiredActive: active))
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private struct Intent: Codable { let desiredActive: Bool }
}
