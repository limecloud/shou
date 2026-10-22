import Foundation

/// Windows identities must retain the entire File ID and SID, without hashing
/// either value into POSIX compatibility fields.
public struct WindowsFileIdentity: Codable, Sendable, Equatable {
    public let volume: UInt64
    public let fileId: String
    public let ownerSid: String
    public init(volume: UInt64, fileId: String, ownerSid: String) {
        self.volume=volume; self.fileId=fileId; self.ownerSid=ownerSid
    }
}

public struct FileEntry: Codable, Sendable, Equatable {
    public var path: String
    public var kind: String
    public var device: UInt64
    public var inode: UInt64
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var modifiedNanoseconds: Int64
    public var changedNanoseconds: Int64
    public var mode: UInt32
    public var owner: UInt32
    public var links: UInt64
    public var contentDigest: String? = nil
    public var windowsIdentity: WindowsFileIdentity? = nil
    public init(path: String, kind: String, device: UInt64, inode: UInt64, logicalBytes: Int64, allocatedBytes: Int64, modifiedNanoseconds: Int64, changedNanoseconds: Int64, mode: UInt32, owner: UInt32, links: UInt64) {
        self.path=path; self.kind=kind; self.device=device; self.inode=inode; self.logicalBytes=logicalBytes; self.allocatedBytes=allocatedBytes
        self.modifiedNanoseconds=modifiedNanoseconds; self.changedNanoseconds=changedNanoseconds; self.mode=mode; self.owner=owner; self.links=links
    }
    public func sameObject(as other: FileEntry) -> Bool {
        if windowsIdentity != nil || other.windowsIdentity != nil {
            guard let a=windowsIdentity, let b=other.windowsIdentity else { return false }
            return a.volume == b.volume && a.fileId == b.fileId && kind == other.kind
        }
        return device == other.device && inode == other.inode && kind == other.kind
    }
    public func hasSameOwner(as other: FileEntry) -> Bool {
        if windowsIdentity != nil || other.windowsIdentity != nil {
            guard let a=windowsIdentity, let b=other.windowsIdentity else { return false }
            return a.ownerSid == b.ownerSid
        }
        return owner == other.owner
    }
    public var objectIdentityKey: String {
        if let identity=windowsIdentity { return "windows:\(identity.volume):\(identity.fileId)" }
        return "posix:\(device):\(inode)"
    }
    public var metadata: FileEntry { var copy=self; copy.contentDigest=nil; return copy }
    public func matchesTrashRoot(as other: FileEntry) -> Bool {
        guard path == ".", other.path == ".", kind == other.kind,
              kind == "directory" || (kind == "file" && contentDigest != nil && contentDigest == other.contentDigest) else { return false }
        // File roots additionally require the same bounded content digest.
        var normalized=other
        normalized.changedNanoseconds=changedNanoseconds
        return self == normalized
    }
}

public struct ScanBudget: Codable, Sendable {
    public var maxEntries: Int
    public var maxSeconds: TimeInterval
    public var maxDepth: Int
    public init(maxEntries: Int = 100_000, maxSeconds: TimeInterval = 60, maxDepth: Int = 128) {
        self.maxEntries=maxEntries; self.maxSeconds=maxSeconds; self.maxDepth=maxDepth
    }
    func validate() throws {
        guard (1...1_000_000).contains(maxEntries), maxSeconds.isFinite,
              (1...600).contains(maxSeconds), (1...128).contains(maxDepth) else {
            throw ShouError("invalid_argument", "Scan budget is outside supported limits.")
        }
    }
}

public struct ScanProgress: Sendable {
    public let stage: String
    public let entryCount: Int
    public let currentPath: String
    public let limitReached: Bool
    public let completedUnitCount: Int?
    public let totalUnitCount: Int?
    /// Completion of the reported known work, not elapsed time or disk coverage.
    /// Rule scans count discovery, matching and persistence phases across the batch.
    public var fractionCompleted: Double? {
        guard let completedUnitCount, let totalUnitCount, totalUnitCount > 0,
              completedUnitCount >= 0, completedUnitCount <= totalUnitCount else { return nil }
        return Double(completedUnitCount) / Double(totalUnitCount)
    }
    public init(stage: String, entryCount: Int, currentPath: String = "", limitReached: Bool = false,
                completedUnitCount: Int? = nil, totalUnitCount: Int? = nil) {
        self.stage=stage; self.entryCount=entryCount; self.currentPath=currentPath; self.limitReached=limitReached
        self.completedUnitCount=completedUnitCount; self.totalUnitCount=totalUnitCount
    }
}

public enum ScanScope: String, Codable, Sendable {
    case full
    case cleanup
}

public struct ExecutionProgress: Sendable {
    public let stage: String
    public let processedCount: Int
    public let itemCount: Int
    public let path: String
    public let currentItemProcessedCount: Int?
    public let currentItemCount: Int?
    public var fractionCompleted: Double? {
        guard itemCount > 0, processedCount >= 0, processedCount <= itemCount else { return nil }
        var completed=Double(processedCount)
        if processedCount < itemCount, let done=currentItemProcessedCount, let total=currentItemCount,
           total > 0, done >= 0, done <= total { completed += Double(done) / Double(total) }
        return min(1, completed / Double(itemCount))
    }
    public init(stage: String, processedCount: Int, itemCount: Int, path: String = "",
                currentItemProcessedCount: Int? = nil, currentItemCount: Int? = nil) {
        self.stage=stage; self.processedCount=processedCount; self.itemCount=itemCount; self.path=path
        self.currentItemProcessedCount=currentItemProcessedCount; self.currentItemCount=currentItemCount
    }
}

public struct TreeSnapshot: Codable, Sendable {
    public var entries: [FileEntry]
    public var complete: Bool
    public var issues: [String]
    public var caseSensitive: Bool
    public var completedPaths: [String]?
    public var discoveryComplete: Bool?
    public init(entries: [FileEntry], complete: Bool, issues: [String], caseSensitive: Bool, completedPaths: [String]? = nil, discoveryComplete: Bool? = nil) {
        self.entries=entries; self.complete=complete; self.issues=issues; self.caseSensitive=caseSensitive
        self.completedPaths=completedPaths
        self.discoveryComplete=discoveryComplete
    }
    public func isComplete(at path: String) -> Bool {
        complete || (completedPaths ?? []).contains { completed in
            completed == "." || path == completed || path.hasPrefix(completed + "/")
        }
    }
}

public struct Workspace: Codable, Sendable, Identifiable {
    public var id: String
    public var rootRef: String
    public var path: String
    public var identity: FileEntry
    public var exclusions: [String]
    public var protectedRelativePaths: [String]? = nil
    public var addedAt: Date
}
public struct RuleRecord: Codable, Sendable, Identifiable {
    public var id: String { rule.id + "@" + rule.version }
    public var rule: CleanupRule
    public var digest: String
    public var importedAt: Date
    public var provenance: String
}
public struct RuleBinding: Codable, Sendable {
    public var workspaceId: String
    public var ruleId: String
    public var version: String
    public var enabled: Bool
}
public struct Preset: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var workspaceId: String
    public var ruleIds: [String]
}
public struct Configuration: Codable, Sendable {
    public var version = 1
    public var revision = Codec.id("config")
    public var workspaces: [Workspace] = []
    public var rules: [RuleRecord] = []
    public var bindings: [RuleBinding] = []
    public var presets: [Preset] = []
    public var locale: String? = nil
    public var globalExclusions: [String]? = nil
    public init() {}
}
public struct Candidate: Codable, Sendable, Identifiable {
    public var id: String
    public var relativePath: String
    public var logicalBytes: Int64
    public var allocatedBytesEstimate: Int64
    public var newestModifiedAt: Date
    public var manifestDigest: String
    public var ruleIds: [String]
    public var ruleVersions: [String: String]
    public var risk: String
    public var reasons: [String]
    public var rebuildNotes: [String]
    public var limitations: [String]
    public var eligible: Bool
}
public struct ScanSnapshot: Codable, Sendable, Identifiable {
    public var id: String
    public var workspace: Workspace
    public var configurationDigest: String
    public var createdAt: Date
    public var status: String
    public var previewOnly: Bool
    public var caseSensitive: Bool
    public var entries: [FileEntry]
    public var candidates: [Candidate]
    public var issues: [String]
    public var budget: ScanBudget? = nil
    public var completedPaths: [String]? = nil
    public var treeComplete: Bool? = nil
    public var scope: ScanScope? = nil
    public var installedApplicationCaches: [InstalledApplicationCacheEvidence]? = nil
}
public struct PlanItem: Codable, Sendable, Identifiable {
    public var id: String
    public var candidate: Candidate
    public var manifest: [FileEntry]
}
public struct CleanupPlan: Codable, Sendable, Identifiable {
    public var id: String
    public var scanId: String
    public var workspace: Workspace
    public var configurationDigest: String
    public var createdAt: Date
    public var expiresAt: Date
    public var items: [PlanItem]
    public var action = "trash"
    public var digest = ""
    public var state = "ready"
    public var executionId: String? = nil
    public var scanBudget: ScanBudget? = nil
    public var scanScope: ScanScope? = nil
    public var installedApplicationCaches: [InstalledApplicationCacheEvidence]? = nil
    public var allocatedBytesEstimate: Int64 { items.reduce(0) { $0 + $1.candidate.allocatedBytesEstimate } }
    public func calculatedDigest() throws -> String {
        var copy = self; copy.digest=""; copy.state="ready"; copy.executionId=nil
        return try Digest.of(copy)
    }
}
public struct ItemReceipt: Codable, Sendable, Identifiable {
    public var id: String
    public var originalPath: String
    public var relativePath: String
    public var trashPath: String?
    public var manifest: [FileEntry]
    public var state: String
    public var allocatedBytesEstimate: Int64
    public var error: String?
    public var uninstallOrigin: UninstallReceiptOrigin? = nil
}
public struct ExecutionReceipt: Codable, Sendable, Identifiable {
    public var id: String
    public var planId: String
    public var workspace: Workspace
    public var createdAt: Date
    public var entryPoint: String
    public var state: String
    public var items: [ItemReceipt]
    public var volumeAvailableBefore: Int64?
    public var volumeAvailableAfter: Int64?
    public var operation: String? = nil
    public var trashedBytesEstimate: Int64 { items.filter { $0.state == "trashed" }.reduce(0) { $0 + $1.allocatedBytesEstimate } }
    public var permanentlyRemovedBytesEstimate: Int64 { items.filter { $0.state == "purged" }.reduce(0) { $0 + $1.allocatedBytesEstimate } }
}
public struct FollowUpReceipt: Codable, Sendable, Identifiable {
    public var id: String
    public var executionId: String
    public var itemId: String
    public var action: String
    public var createdAt: Date
    public var state: String
    public var resultingPath: String?
    public var error: String?
}
public struct TrashResult: Sendable {
    public var path: String
    public var manifest: [FileEntry]
    public var verified: Bool
    public init(path: String, manifest: [FileEntry], verified: Bool) { self.path=path; self.manifest=manifest; self.verified=verified }
}

public protocol StoreLease: Sendable { func release() }
public protocol RecordStore: Sendable {
    var protectedPaths: [String] { get }
    func storageCatalogURL(id: String) throws -> URL?
    func read(_ collection: String, id: String) throws -> Data?
    func write(_ collection: String, id: String, data: Data) throws
    func removeHistoryRecord(_ collection: String, id: String) throws
    func records(_ collection: String) throws -> [StoredRecord]
    func recordMetadata(_ collection: String, id: String) throws -> StoredRecord?
    func removeDerivedRecord(_ record: StoredRecord) throws
    func ids(_ collection: String) throws -> [String]
    func lock() throws -> any StoreLease
}
extension RecordStore {
    public func recordMetadata(_ collection: String, id: String) throws -> StoredRecord? {
        try records(collection).first { $0.id == id }
    }
    public func records(_ collection: String) throws -> [StoredRecord] {
        try ids(collection).compactMap { id in
            guard let data=try read(collection, id: id) else { return nil }
            return StoredRecord(collection: collection, id: id, byteCount: Int64(data.count), modifiedAt: .distantFuture, revision: Digest.sha256(data))
        }
    }
    public func removeDerivedRecord(_ record: StoredRecord) throws {
        throw ShouError("capability_unavailable", "Derived record cleanup is unavailable in this record store.")
    }
    public func removeHistoryRecord(_ collection: String, id: String) throws {
        throw ShouError("capability_unavailable", "History cleanup is unavailable in this record store.")
    }
    public var protectedPaths: [String] { [] }
    public func storageCatalogURL(id: String) throws -> URL? { nil }
}
public enum LocationAvailability: Sendable {
    case available
    case missing
    case unavailable(String)
}

public protocol PlatformFileSystem: Sendable {
    func normalizedPath(_ path: String) throws -> String
    var caseSensitivePaths: Bool { get }
    var platform: String { get }
    /// Batch discovery must stay within the platform's bounded read capacity.
    var maximumConcurrentReadOperations: Int { get }
    var supportsTrash: Bool { get }
    var supportsAuthorizedApplicationTrash: Bool { get }
    var trashUnavailableReason: String? { get }
    func locationAvailability(_ path: String) -> LocationAvailability
    func targetAvailability(_ path: String) -> LocationAvailability
    func rootIdentity(_ path: String) throws -> FileEntry
    func cleanupTargetIdentity(_ path: String) throws -> FileEntry
    func applicationParentIdentity(_ path: String) throws -> FileEntry
    func analysisRootIdentity(_ path: String) throws -> FileEntry
    var supportsStorageCatalog: Bool { get }
    func measureStorage(_ path: String, catalog: URL, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> StorageMeasurement
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot
    func inspectTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot
    func inspectStorageTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot
    func inspectTrashTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot
    func inspectCleanup(_ path: String, rules: [CleanupRule], budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot
    func availableBytes(_ path: String) -> Int64?
    func isTrashLocation(_ path: String) -> Bool
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult
    func moveApplicationToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws
    func purge(_ path: String, expected: [FileEntry]) throws
    func purge(_ path: String, expected: [FileEntry], progress: (Int, Int, String) -> Void) throws
    func purge(_ path: String, expected: [FileEntry], context: inout PermanentRemovalContext, progress: (Int, Int, String) -> Void) throws
}
extension PlatformFileSystem {
    public var maximumConcurrentReadOperations: Int { 4 }
    public var supportsAuthorizedApplicationTrash: Bool { false }
    public func moveApplicationToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult {
        try moveToTrash(path, expected: expected)
    }
    public func purge(_ path: String, expected: [FileEntry], context: inout PermanentRemovalContext, progress: (Int, Int, String) -> Void) throws {
        try purge(path, expected: context.reconciled(expected), progress: progress)
    }
    public func purge(_ path: String, expected: [FileEntry], progress: (Int, Int, String) -> Void) throws {
        try purge(path, expected: expected)
        progress(expected.count, expected.count, path)
    }
    public func normalizedPath(_ path: String) throws -> String { path }
    public var caseSensitivePaths: Bool { true }
    public var supportsStorageCatalog: Bool { false }
    public func measureStorage(_ path: String, catalog: URL, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> StorageMeasurement {
        throw ShouError("capability_unavailable", "Streaming space analysis is unavailable on this filesystem.")
    }
    public func analysisRootIdentity(_ path: String) throws -> FileEntry { try rootIdentity(path) }
    public func cleanupTargetIdentity(_ path: String) throws -> FileEntry { try rootIdentity(path) }
    public func inspectStorageTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        try inspectTarget(path, budget: budget, cancelled: cancelled)
    }
    public func inspectTrashTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        guard isTrashLocation(path) else { throw ShouError("permission_denied", "Only an exact system Trash item can be inspected.") }
        return try inspectStorageTarget(path, budget: budget, cancelled: cancelled)
    }
    public func applicationParentIdentity(_ path: String) throws -> FileEntry {
        throw ShouError("capability_unavailable", "Application removal is unavailable on this filesystem.")
    }
    public var trashUnavailableReason: String? { nil }
    public func targetAvailability(_ path: String) -> LocationAvailability { locationAvailability(path) }
    public func inspectTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        try inspect(path, budget: budget, cancelled: cancelled)
    }
    public func locationAvailability(_ path: String) -> LocationAvailability {
        do { _ = try rootIdentity(path); return .available }
        catch { return .unavailable(error.localizedDescription) }
    }
    public func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        try inspect(path, budget: budget, cancelled: cancelled)
    }
    public func inspectCleanup(_ path: String, rules: [CleanupRule], budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        try inspect(path, budget: budget, cancelled: cancelled, progress: progress)
    }
}
