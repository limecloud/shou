import Foundation

public struct StorageScan: Codable, Sendable, Identifiable {
    public let id: String
    public let rootPath: String
    public let identity: FileEntry
    public let createdAt: Date
    public var tree: TreeSnapshot
    public var status: String { tree.complete ? "complete" : "partial" }
}

public struct StorageRemovalItem: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let manifest: [FileEntry]
    public let allocatedBytesEstimate: Int64
}

public struct StorageRemovalPlan: Codable, Sendable, Identifiable {
    public let id: String
    public let scanId: String
    public let rootPath: String
    public let identity: FileEntry
    public let createdAt: Date
    public let expiresAt: Date
    public let action: String
    public let items: [StorageRemovalItem]
    public var state: String = "ready"
    public var digest: String = ""
    public var allocatedBytesEstimate: Int64 { items.reduce(0) { $0 + $1.allocatedBytesEstimate } }
    public func calculatedDigest() throws -> String {
        var copy=self; copy.digest=""; copy.state="ready"
        return try Digest.of(copy)
    }
}

/// Selection contains disjoint, literal paths. Unchecking a covered child
/// expands only the selected ancestry, preserving every other sibling.
public enum StorageSelection {
    public static func normalized(_ paths: Set<String>) -> Set<String> {
        var result=Set<String>()
        for path in paths.sorted(by: { $0.count < $1.count }) {
            if !result.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { result.insert(path) }
        }
        return result
    }
    public static func contains(_ path: String, in paths: Set<String>) -> Bool {
        paths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    public static func toggle(_ path: String, selected: Bool, paths: Set<String>, index: StorageIndex) -> Set<String> {
        if selected { return normalized(paths.union([path])) }
        var result=paths.filter { $0 != path && !$0.hasPrefix(path + "/") }
        if let ancestor=paths.first(where: { path.hasPrefix($0 + "/") }) {
            result.remove(ancestor)
            var current=ancestor
            while current != path {
                let children=index.children(of: current)
                guard let next=children.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else { break }
                result.formUnion(children.filter { $0.path != next.path }.map(\.path))
                current=next.path
            }
        }
        return result
    }
}

public enum StorageRemovalPolicy {
    public static func canonical(_ path: String) -> String {
        path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
    }
    public static func absolute(root: String, relative: String) -> String {
        relative == "." ? root : (root == "/" ? "/" : root + "/") + relative
    }
    public static func validRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    public static func reason(root: String, path: String, entry: FileEntry, home: String, protectedPaths: [String]) -> String? {
        guard validRelative(path), ["file", "directory"].contains(entry.kind) else { return "Links, special files and the scan root cannot be removed here." }
        let absolute=absolute(root: root, relative: path)
        let canonical=canonical(absolute)
        let system=["/System", "/usr", "/bin", "/sbin", "/dev", "/etc", "/private/etc", "/private/var/db", "/Library/Apple", "/Library/Security"]
        if system.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }) { return "This system location is protected." }
        let containers=["/", "/Users", "/Applications", "/Volumes", "/opt", "/Library", "/private", "/private/var", "/private/var/folders", home, home + "/Library"]
        let protected=[home + "/.Trash", home + "/.ssh", home + "/.gnupg", home + "/Library/Mobile Documents", home + "/Library/CloudStorage"] + protectedPaths
        if containers.contains(canonical) || protected.contains(where: { canonical == $0 || $0.hasPrefix(canonical + "/") || canonical.hasPrefix($0 + "/") }) { return "This location contains protected data." }
        return nil
    }
}

extension ShouEngine {
    public func scanStorage(path: String, budget: ScanBudget = ScanBudget(maxEntries: 1_000_000, maxSeconds: 600), progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> StorageScan {
        try budget.validate()
        guard path == "/" || (path.hasPrefix("/") && StorageRemovalPolicy.validRelative(String(path.dropFirst()))) else { throw ShouError("invalid_argument", "Select an absolute normalized analysis root.") }
        let identity=try filesystem.analysisRootIdentity(path)
        let tree=try filesystem.inspect(path, budget: budget, cancelled: { Task.isCancelled }, progress: progress)
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        guard tree.entries.first(where: { $0.path == "." })?.sameObject(as: identity) == true else { throw ShouError("plan_stale", "Analysis root changed during scanning.") }
        let scan=StorageScan(id: Codec.id("storage"), rootPath: path, identity: identity, createdAt: now(), tree: tree)
        progress(ScanProgress(stage: "saving", entryCount: tree.entries.count, currentPath: path, limitReached: tree.issues.contains("resource_limit")))
        try StorageScanRecords.save(scan, store: store) {
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        }
        return scan
    }
    public func storageScan(_ id: String) throws -> StorageScan {
        try StorageScanRecords.load(id, store: store)
    }
    public func storageRemovalReason(scan: StorageScan, path: String) -> String? {
        guard let entry=scan.tree.entries.first(where: { $0.path == path }) else { return "Item is absent from this analysis." }
        if entry.owner != scanOwner() { return "This item is not owned by the current user." }
        if let reason=StorageRemovalPolicy.reason(root: scan.rootPath, path: path, entry: entry, home: homeDirectory.path, protectedPaths: store.protectedPaths) { return reason }
        return storageExclusionReason(scan: scan, entries: scan.tree.entries.filter { $0.path == path || $0.path.hasPrefix(path + "/") })
    }
    private func storageExclusionReason(scan: StorageScan, entries: [FileEntry]) -> String? {
        guard let config=try? configuration() else { return "Cleanup exclusions could not be verified." }
        for root in config.workspaces {
            let prefix=StorageRemovalPolicy.canonical(root.path) + "/"
            let patterns=(config.globalExclusions ?? []) + root.exclusions
            for entry in entries {
                let full=StorageRemovalPolicy.canonical(StorageRemovalPolicy.absolute(root: scan.rootPath, relative: entry.path))
                if full.hasPrefix(prefix) {
                    let relative=String(full.dropFirst(prefix.count))
                    if patterns.contains(where: { PathPattern.matches($0, relative, caseSensitive: scan.tree.caseSensitive) }) { return "This selection contains excluded content." }
                }
            }
        }
        return nil
    }
    private func scanOwner() -> UInt32 {
        // The platform supplies the current home identity without granting a cleanup root.
        (try? filesystem.analysisRootIdentity(homeDirectory.path).owner) ?? UInt32.max
    }
    public func createStorageRemovalPlan(scanId: String, paths: [String], action: String = "trash", budget: ScanBudget = ScanBudget(maxEntries: 1_000_000, maxSeconds: 600)) throws -> StorageRemovalPlan {
        try budget.validate()
        guard ["trash", "permanent"].contains(action), !paths.isEmpty, paths.count <= 5000,
              paths.allSatisfy(StorageRemovalPolicy.validRelative) else { throw ShouError("invalid_argument", "Select explicit file or directory paths and a supported removal mode.") }
        let lease=try store.lock(); defer { lease.release() }
        let scan=try storageScan(scanId)
        guard try filesystem.analysisRootIdentity(scan.rootPath).sameObject(as: scan.identity) else { throw ShouError("plan_stale", "Analysis root changed.") }
        var items=[StorageRemovalItem]()
        for path in StorageSelection.normalized(Set(paths)).sorted() {
            if Task.isCancelled { throw ShouError("cancelled", "Selection review stopped.") }
            if let reason=storageRemovalReason(scan: scan, path: path) { throw ShouError("permission_denied", reason, details: ["path": path]) }
            let full=StorageRemovalPolicy.absolute(root: scan.rootPath, relative: path)
            let tree=try filesystem.inspectStorageTarget(full, budget: budget, cancelled: { Task.isCancelled })
            guard tree.complete, let current=tree.entries.first(where: { $0.path == "." }),
                  let saved=scan.tree.entries.first(where: { $0.path == path }), current.metadata == renamed(saved, to: ".").metadata else { throw ShouError("plan_stale", "Selected item changed or could not be completely measured.", details: ["path": path]) }
            if let reason=storageExclusionReason(scan: scan, entries: tree.entries.map { renamed($0, to: $0.path == "." ? path : path + "/" + $0.path) }) {
                throw ShouError("permission_denied", reason, details: ["path": path])
            }
            let bytes=StorageIndex(entries: tree.entries).nodes["."]?.allocatedBytes ?? 0
            items.append(StorageRemovalItem(path: path, manifest: tree.entries, allocatedBytesEstimate: bytes))
        }
        var plan=StorageRemovalPlan(id: Codec.id("storage-plan"), scanId: scan.id, rootPath: scan.rootPath, identity: scan.identity, createdAt: now(), expiresAt: now().addingTimeInterval(900), action: action, items: items)
        plan.digest=try plan.calculatedDigest()
        try store.write("storage-plans", id: plan.id, data: Codec.encode(plan))
        return plan
    }
    private func renamed(_ entry: FileEntry, to path: String) -> FileEntry { var copy=entry; copy.path=path; return copy }
    public func storageRemovalPlan(_ id: String) throws -> StorageRemovalPlan {
        guard let data=try store.read("storage-plans", id: id) else { throw ShouError("invalid_argument", "Unknown space removal plan.") }
        return try Codec.decode(StorageRemovalPlan.self, from: data)
    }
    public func executeStorageRemoval(planId: String, confirmedDigest: String, entryPoint: String, progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> ExecutionReceipt {
        let lease=try store.lock(); defer { lease.release() }
        let plan=try storageRemovalPlan(planId)
        guard plan.state == "ready" else { throw ShouError("already_executed", "This removal was already started.") }
        guard plan.expiresAt > now(), try plan.calculatedDigest() == plan.digest, plan.digest == confirmedDigest else { throw ShouError("confirmation_required", "Removal confirmation expired or does not match.") }
        let scan=try storageScan(plan.scanId)
        guard plan.rootPath == scan.rootPath, plan.identity.sameObject(as: scan.identity),
              ["trash", "permanent"].contains(plan.action), !plan.items.isEmpty,
              Set(plan.items.map(\.path)).count == plan.items.count,
              StorageSelection.normalized(Set(plan.items.map(\.path))).count == plan.items.count else { throw ShouError("store_corrupt", "Removal scope is invalid.") }
        let workspace=Workspace(id: scan.id, rootRef: "space-analysis", path: scan.rootPath, identity: scan.identity, exclusions: [], addedAt: scan.createdAt)
        let items=plan.items.map { ItemReceipt(id: Codec.id("item"), originalPath: StorageRemovalPolicy.absolute(root: plan.rootPath, relative: $0.path), relativePath: $0.path, trashPath: nil, manifest: $0.manifest, state: "pending", allocatedBytesEstimate: $0.allocatedBytesEstimate, error: nil) }
        let began: (ExecutionReceipt) throws -> Void = { _ in
            var started=plan; started.state="executing"
            try self.store.write("storage-plans", id: started.id, data: Codec.encode(started))
        }
        let validate: (Int) throws -> String? = { index in
            guard try self.filesystem.analysisRootIdentity(scan.rootPath).sameObject(as: scan.identity) else { throw ShouError("plan_stale", "Analysis root changed.") }
            let item=plan.items[index]
            if let reason=self.storageRemovalReason(scan: scan, path: item.path) { return reason }
            let tree=try self.filesystem.inspectStorageTarget(items[index].originalPath, budget: ScanBudget(maxEntries: 1_000_000, maxSeconds: 600), cancelled: { Task.isCancelled })
            guard tree.complete, tree.entries == item.manifest,
                  let saved=scan.tree.entries.first(where: { $0.path == item.path }),
                  tree.entries.first(where: { $0.path == "." })?.metadata == self.renamed(saved, to: ".").metadata else { throw ShouError("plan_stale", "Selected item changed since confirmation.") }
            if let reason=self.storageExclusionReason(scan: scan, entries: tree.entries.map { self.renamed($0, to: $0.path == "." ? item.path : item.path + "/" + $0.path) }) { return reason }
            return nil
        }
        if plan.action == "permanent" {
            return try PermanentExecution.run(planId: plan.id, workspace: workspace, items: items, entryPoint: entryPoint, store: store, filesystem: filesystem, now: now(), operation: "storage_permanent_removal", progress: progress, didBegin: began, validateItem: validate)
        }
        return try TrashExecution.run(planId: plan.id, workspace: workspace, items: items, entryPoint: entryPoint, store: store, filesystem: filesystem, now: now(), operation: "storage_removal", progress: progress, didBegin: began, validateItem: validate)
    }
}
