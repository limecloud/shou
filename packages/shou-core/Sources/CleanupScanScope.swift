import Foundation

public enum CleanupScanScope: Sendable {
    case standard
    case folders([String])
    case volumes([String])
}

public struct CleanupScanVolume: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isSystem: Bool
    public init(path: String, name: String, isSystem: Bool) {
        self.path=path; self.name=name; self.isSystem=isSystem
    }
}

public struct CleanupDirectoryListing: Sendable {
    public let paths: [String]
    public let complete: Bool
    public init(paths: [String], complete: Bool = true) { self.paths=paths; self.complete=complete }
}

/// Read-only discovery; returned paths still pass the ordinary workspace checks.
public protocol CleanupLocationReading: Sendable {
    func childDirectories(_ path: String) throws -> CleanupDirectoryListing
    func localVolumes() throws -> [CleanupScanVolume]
}
