import Foundation

public struct StorageScan: Codable, Sendable, Identifiable {
    public let id: String
    public let rootPath: String
    public let identity: FileEntry
    public let createdAt: Date
    public var tree: TreeSnapshot
    public var catalogId: String? = nil
    public var measuredEntryCount: Int? = nil
    public var entryCount: Int { measuredEntryCount ?? tree.entries.count }
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
    public var items: [StorageRemovalItem]
    public var manifestFormatVersion: Int? = nil
    public var state: String = "ready"
    public var digest: String = ""
    public var allocatedBytesEstimate: Int64 { items.reduce(0) { $0 + $1.allocatedBytesEstimate } }
    public func calculatedDigest() throws -> String {
        if manifestFormatVersion == 1 { return try StorageRemovalPlanRecords.digest(self) }
        var copy=self; copy.digest=""; copy.state="ready"
        return try Digest.of(copy)
    }
}

/// Selection contains disjoint, literal paths. Unchecking a covered child
/// expands only the selected ancestry, preserving every other sibling.
public enum StorageSelection {
    public static func normalized(_ paths: Set<String>) -> Set<String> {
        paths.filter { path in
            var parent=StorageIndex.parent(path)
            while parent != "." {
                if paths.contains(parent) { return false }
                parent=StorageIndex.parent(parent)
            }
            return true
        }
    }
    public static func contains(_ path: String, in paths: Set<String>) -> Bool {
        if paths.contains(path) { return true }
        var parent=StorageIndex.parent(path)
        while parent != "." {
            if paths.contains(parent) { return true }
            parent=StorageIndex.parent(parent)
        }
        return false
    }
    /// Apply a folder selection once, rather than normalizing the growing set
    /// for every sibling. Descendant exclusions expand only their ancestry.
    public static func setting(_ targets: Set<String>, selected: Bool, in paths: Set<String>, index: StorageIndex) -> Set<String> {
        if selected { return normalized(paths.union(targets)) }
        let excluded=normalized(targets)
        var ancestors=Set<String>()
        for target in excluded {
            var parent=StorageIndex.parent(target)
            while parent != "." {
                ancestors.insert(parent)
                parent=StorageIndex.parent(parent)
            }
        }
        var pending=Array(paths), result=Set<String>()
        while let path=pending.popLast() {
            if contains(path, in: excluded) { continue }
            if ancestors.contains(path) { pending.append(contentsOf: index.children(of: path).map(\.path)) }
            else { result.insert(path) }
        }
        return result
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
    /// Only disposable, direct catalog files are exempt from record protection.
    public static func isRemovableCatalog(_ absolutePath: String, entry: FileEntry, recordDirectory: String) -> Bool {
        guard entry.kind == "file", entry.links == 1 else { return false }
        let prefix=canonical(recordDirectory) + "/storage-catalogs/", path=canonical(absolutePath)
        guard path.hasPrefix(prefix), path.hasSuffix(".sqlite") else { return false }
        let id=path.dropFirst(prefix.count).dropLast(".sqlite".count)
        return (1...120).contains(id.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    public static func canonical(_ path: String) -> String {
        path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
    }
    public static func absolute(root: String, relative: String) -> String {
        relative == "." ? root : (root == "/" ? "/" : root + "/") + relative
    }
    public static func validRelative(_ path: String) -> Bool {
        var length=0, onlyDots=true
        for byte in path.utf8 {
            if byte == 0 { return false }
            if byte == 47 {
                if length == 0 || (onlyDots && length <= 2) { return false }
                length=0; onlyDots=true
            } else { length += 1; onlyDots = onlyDots && byte == 46 }
        }
        return length > 0 && !(onlyDots && length <= 2)
    }
    public static func reason(root: String, path: String, entry: FileEntry, home: String, protectedPaths: [String]) -> String? {
        guard validRelative(path), ["file", "directory"].contains(entry.kind) else { return "Links, special files and the scan root cannot be removed here." }
        let absolute=absolute(root: root, relative: path)
        let canonical=canonical(absolute)
        let system=["/System", "/usr", "/bin", "/sbin", "/dev", "/etc", "/private/etc", "/private/var/db", "/Library/Apple", "/Library/Security"]
        if system.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }) { return "This system location is protected." }
        let containers=["/", "/Users", "/Applications", "/Volumes", "/opt", "/Library", "/private", "/private/var", "/private/var/folders", home, home + "/Library"]
        let protected=[home + "/.Trash", home + "/.ssh", home + "/.gnupg", home + "/Library/Mobile Documents", home + "/Library/CloudStorage"] + protectedPaths.filter {
            !isRemovableCatalog(canonical, entry: entry, recordDirectory: $0)
        }.map { Self.canonical($0) }
        if containers.contains(canonical) || protected.contains(where: { canonical == $0 || $0.hasPrefix(canonical + "/") || canonical.hasPrefix($0 + "/") }) { return "This location contains protected data." }
        return nil
    }
}

extension ShouEngine {
    /// An explicit manual selection uses the same direct-removal contract as
    /// Space Analysis. Rule discovery is navigation, never removal authority.
    public func createReviewedCleanupRemovalPlan(scanId: String, candidateIds: [String], action: String = "permanent") throws -> StorageRemovalPlan {
        guard ["trash", "permanent"].contains(action), !candidateIds.isEmpty, candidateIds.count <= 5000, Set(candidateIds).count == candidateIds.count else {
            throw ShouError("invalid_argument", "Explicit, unique candidate IDs are required.")
        }
        let snapshot=try scanSnapshot(scanId)
        let config=try configuration()
        guard !snapshot.previewOnly else { throw ShouError("partial_result", "Draft previews cannot produce executable plans.") }
        guard try Digest.of(config) == snapshot.configurationDigest,
              config.workspaces.contains(where: { $0.id == snapshot.workspace.id && $0.path == snapshot.workspace.path && $0.rootRef == snapshot.workspace.rootRef }) else {
            throw ShouError("plan_stale", "Configuration changed; scan again.")
        }
        let identity=try filesystem.analysisRootIdentity(snapshot.workspace.path)
        guard identity.sameObject(as: snapshot.workspace.identity), identity.hasSameOwner(as: snapshot.workspace.identity) else {
            throw ShouError("plan_stale", "Analysis root changed.")
        }
        let selected=try candidateIds.map { id -> FileEntry in
            guard let candidate=snapshot.candidates.first(where: { $0.id == id && !$0.ruleIds.isEmpty }),
                  StorageRemovalPolicy.validRelative(candidate.relativePath),
                  let entry=snapshot.entries.first(where: { $0.path == candidate.relativePath && $0.kind == "directory" }) else {
                throw ShouError("invalid_argument", "Candidate is missing, protected, excluded, or unclassified.", details: ["candidate": id])
            }
            return entry
        }
        let scan=StorageScan(id: Codec.id("storage"), rootPath: snapshot.workspace.path, identity: identity, createdAt: now(),
            tree: TreeSnapshot(entries: [identity] + selected, complete: false, issues: [], caseSensitive: snapshot.caseSensitive))
        try StorageScanRecords.save(scan, store: store) {
            if Task.isCancelled { throw ShouError("cancelled", "Selection review stopped.") }
        }
        // The shared planner remeasures each exact target and enforces owner,
        // exclusions, protected locations, no-follow reads and complete scope.
        return try createStorageRemovalPlan(scanId: scan.id, paths: selected.map(\.path), action: action)
    }

    public func scanStorage(path: String, budget: ScanBudget? = nil, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> StorageScan {
        maintainDerivedRecordsIfNeeded()
        let path=try filesystem.normalizedPath(path)
        try budget?.validate()
        let drivePath=path.count >= 3 && path.prefix(1).allSatisfy({ $0.isASCII && $0.isLetter }) && path.dropFirst().hasPrefix(":/") && (path.count == 3 || StorageRemovalPolicy.validRelative(String(path.dropFirst(3))))
        guard path == "/" || drivePath || (path.hasPrefix("/") && StorageRemovalPolicy.validRelative(String(path.dropFirst()))) else { throw ShouError("invalid_argument", "Select an absolute normalized analysis root.") }
        let identity=try filesystem.analysisRootIdentity(path)
        let id=Codec.id("storage")
        if budget == nil, filesystem.supportsStorageCatalog, let url=try store.storageCatalogURL(id: id) {
            var published=false
            defer { if !published { try? FileManager.default.removeItem(at: url) } }
            let measurement=try filesystem.measureStorage(path, catalog: url, cancelled: { Task.isCancelled }, progress: progress)
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            guard measurement.tree.entries.first?.sameObject(as: identity) == true else { throw ShouError("plan_stale", "Analysis root changed during scanning.") }
            var scan=StorageScan(id: id, rootPath: path, identity: measurement.tree.entries[0], createdAt: now(), tree: measurement.tree)
            scan.catalogId=id; scan.measuredEntryCount=measurement.entryCount
            // Small scans retain their legacy inline evidence for compatibility.
            if measurement.entryCount <= 10_000 {
                var entries=[FileEntry]()
                try StorageCatalog(url: url).forEachEntry { entries.append($0) }
                scan.tree.entries=entries.sorted { $0.path < $1.path }
            }
            progress(ScanProgress(stage: "saving", entryCount: measurement.entryCount, currentPath: path))
            try StorageScanRecords.save(scan, store: store, progress: { completed, total in
                progress(ScanProgress(stage: "saving", entryCount: measurement.entryCount, currentPath: path,
                    limitReached: measurement.tree.issues.contains("resource_limit"), completedUnitCount: completed, totalUnitCount: total))
            }) {
                if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            }
            published=true
            return scan
        }
        let tree=try filesystem.inspect(path, budget: budget ?? ScanBudget(maxEntries: 1_000_000, maxSeconds: 600), cancelled: { Task.isCancelled }, progress: progress)
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        guard tree.entries.first(where: { $0.path == "." })?.sameObject(as: identity) == true else { throw ShouError("plan_stale", "Analysis root changed during scanning.") }
        let scan=StorageScan(id: id, rootPath: path, identity: identity, createdAt: now(), tree: tree)
        progress(ScanProgress(stage: "saving", entryCount: tree.entries.count, currentPath: path, limitReached: tree.issues.contains("resource_limit")))
        try StorageScanRecords.save(scan, store: store, progress: { completed, total in
            progress(ScanProgress(stage: "saving", entryCount: tree.entries.count, currentPath: path,
                limitReached: tree.issues.contains("resource_limit"), completedUnitCount: completed, totalUnitCount: total))
        }) {
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        }
        return scan
    }
    public func storageScan(_ id: String) throws -> StorageScan {
        let scan=try StorageScanRecords.load(id, store: store)
        _ = try storageCatalogURL(for: scan)
        return scan
    }
    private func storageCatalogURL(for scan: StorageScan) throws -> URL? {
        guard let id=scan.catalogId else { return nil }
        guard id == scan.id, let url=try store.storageCatalogURL(id: id) else { throw ShouError("store_corrupt", "Space analysis index is missing.") }
        guard try store.recordMetadata("storage-catalogs", id: id) != nil else {
            throw ShouError("analysis_unavailable", "This space analysis was cleared. Scan again.")
        }
        return url
    }
    func catalog(for scan: StorageScan) throws -> StorageCatalog? {
        guard let url=try storageCatalogURL(for: scan) else { return nil }
        let catalog=try StorageCatalog(url: url)
        guard try catalog.entry(at: ".")?.entry == scan.identity else { throw ShouError("store_corrupt", "Space analysis index belongs to a different root.") }
        return catalog
    }
    func storageEntry(scan: StorageScan, path: String) throws -> FileEntry? {
        if let catalog=try catalog(for: scan) { return try catalog.entry(at: path)?.entry }
        return scan.tree.entries.first { $0.path == path }
    }
    public func storageDirectory(scanId: String, path: String = ".") throws -> StorageDirectory {
        guard path == "." || StorageRemovalPolicy.validRelative(path) else { throw ShouError("invalid_argument", "Use an exact directory path in this analysis.") }
        let scan=try storageScan(scanId)
        if let catalog=try catalog(for: scan) {
            guard let item=try catalog.entry(at: path), item.entry.kind == "directory" else { throw ShouError("invalid_argument", "Directory is absent from this analysis.") }
            return StorageDirectory(item: item, children: try catalog.children(of: path))
        }
        let index=StorageIndex(tree: scan.tree), entries=Dictionary(uniqueKeysWithValues: scan.tree.entries.map { ($0.path, $0) })
        guard let node=index.nodes[path], let entry=entries[path], entry.kind == "directory" else { throw ShouError("invalid_argument", "Directory is absent from this analysis.") }
        return StorageDirectory(item: StorageCatalogItem(entry: entry, node: node), children: index.children(of: path).compactMap { node in
            entries[node.path].map { StorageCatalogItem(entry: $0, node: node) }
        })
    }
    func storageReviewContext(scan: StorageScan) throws -> StorageReviewContext {
        try StorageReviewContext(scan: scan, catalog: catalog(for: scan), configuration: configuration(), owner: scanOwner())
    }
    public func storageRemovalReason(scan: StorageScan, path: String) -> String? {
        do { return try storageRemovalReason(scan: scan, path: path, context: storageReviewContext(scan: scan)) }
        catch { return "Cleanup exclusions could not be verified." }
    }
    func storageRemovalReason(scan: StorageScan, path: String, entry: FileEntry? = nil, context: StorageReviewContext, checkDescendants: Bool = true) throws -> String? {
        guard let entry=try entry ?? context.entry(path) else { return "Item is absent from this analysis." }
        if entry.owner != context.owner { return "This item is not owned by the current user." }
        if let reason=StorageRemovalPolicy.reason(root: scan.rootPath, path: path, entry: entry, home: homeDirectory.path, protectedPaths: store.protectedPaths) { return reason }
        return try checkDescendants && context.containsExclusion(under: path) ? "This selection contains excluded content." : nil
    }
    private func scanOwner() -> UInt32 {
        // The platform supplies the current home identity without granting a cleanup root.
        return (try? filesystem.analysisRootIdentity(homeDirectory.path).owner) ?? UInt32.max
    }
    public func createStorageRemovalPlan(scanId: String, paths: [String], action: String = "trash", budget: ScanBudget = ScanBudget(maxEntries: 1_000_000, maxSeconds: 600), progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> StorageRemovalPlan {
        let review=try prepareStorageRemoval(scanId: scanId, paths: paths, action: action, budget: budget, skipUnavailable: false, progress: progress)
        guard let plan=review.plan else { throw ShouError("invalid_argument", "Select explicit file or directory paths and a supported removal mode.") }
        return plan
    }
    /// A desktop batch can omit unavailable targets without granting them a
    /// manifest or execution authority. Strict CLI planning remains unchanged.
    public func reviewStorageRemoval(scanId: String, paths: [String], action: String = "permanent", budget: ScanBudget = ScanBudget(maxEntries: 1_000_000, maxSeconds: 600), progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> (plan: StorageRemovalPlan?, skippedItems: [ItemReceipt]) {
        try prepareStorageRemoval(scanId: scanId, paths: paths, action: action, budget: budget, skipUnavailable: true, progress: progress)
    }
    private func prepareStorageRemoval(scanId: String, paths: [String], action: String, budget: ScanBudget, skipUnavailable: Bool, progress: @Sendable (ExecutionProgress) -> Void) throws -> (plan: StorageRemovalPlan?, skippedItems: [ItemReceipt]) {
        try budget.validate()
        guard ["trash", "permanent"].contains(action), !paths.isEmpty, paths.count <= 5000,
              paths.allSatisfy(StorageRemovalPolicy.validRelative) else { throw ShouError("invalid_argument", "Select explicit file or directory paths and a supported removal mode.") }
        let lease=try store.lock(); defer { lease.release() }
        let scan=try storageScan(scanId)
        guard try filesystem.analysisRootIdentity(scan.rootPath).sameObject(as: scan.identity) else { throw ShouError("plan_stale", "Analysis root changed.") }
        var items=[StorageRemovalItem](), skippedItems=[ItemReceipt]()
        let context=try storageReviewContext(scan: scan)
        let selected=StorageSelection.normalized(Set(paths)).sorted()
        for path in selected {
            if Task.isCancelled { throw ShouError("cancelled", "Selection review stopped.") }
            let full=StorageRemovalPolicy.absolute(root: scan.rootPath, relative: path)
            do {
                if let reason=try storageRemovalReason(scan: scan, path: path, context: context, checkDescendants: false) { throw ShouError("permission_denied", reason, details: ["path": path]) }
                progress(ExecutionProgress(stage: "preparing", processedCount: 0, itemCount: selected.count, path: full))
                let tree=try filesystem.inspectStorageTarget(full, budget: budget, cancelled: { Task.isCancelled }, progress: { update in
                    let current=update.currentPath.isEmpty ? full : update.currentPath.hasPrefix("/") ? update.currentPath : full + "/" + update.currentPath
                    progress(ExecutionProgress(stage: "preparing", processedCount: 0, itemCount: selected.count, path: current))
                })
                guard tree.complete else {
                    throw ShouError(tree.issues.contains("resource_limit") ? "resource_limit" : "incomplete_scan",
                        "This selection could not be completely read. Review access or scan again.", details: ["path": path, "reasons": tree.issues.prefix(10).joined(separator: ",")])
                }
                // Discovery is a navigation snapshot. A fresh manifest determines the scope
                // shown for confirmation; replacing the selected object still invalidates it.
                // The current disposable index can grow until its scan is sealed.
                guard let current=tree.entries.first(where: { $0.path == "." }),
                      let saved=try context.entry(path), current.sameObject(as: saved), current.hasSameOwner(as: saved),
                      current.kind == "directory" || current.metadata == renamed(saved, to: ".").metadata ||
                      store.protectedPaths.contains(where: { StorageRemovalPolicy.isRemovableCatalog(full, entry: current, recordDirectory: $0) }) else { throw ShouError("plan_stale", "Selected item changed. Scan again before removing it.", details: ["path": path]) }
                if context.containsExclusion(path: path, manifest: tree.entries) {
                    throw ShouError("permission_denied", "This selection contains excluded content.", details: ["path": path])
                }
                var charged=Set<String>(), bytes: Int64=0
                for entry in tree.entries where entry.kind != "symlink" && entry.kind != "special" {
                    if entry.links <= 1 || charged.insert(entry.objectIdentityKey).inserted { bytes += max(0, entry.allocatedBytes) }
                }
                items.append(StorageRemovalItem(path: path, manifest: tree.entries, allocatedBytesEstimate: bytes))
                progress(ExecutionProgress(stage: "preparing", processedCount: 0, itemCount: selected.count, path: full))
            } catch let error as ShouError where skipUnavailable && !Task.isCancelled && ["permission_denied", "io_error", "incomplete_scan", "resource_limit"].contains(error.code) {
                let diagnostic=([error.message] + [error.details["reasons"]].compactMap { $0 }).joined(separator: "\n")
                skippedItems.append(ItemReceipt(id: Codec.id("item"), originalPath: full, relativePath: path, trashPath: nil,
                    manifest: [], state: "skipped", allocatedBytesEstimate: 0, error: diagnostic, accessRequirement:error.accessRequirement))
            }
        }
        if Task.isCancelled { throw ShouError("cancelled", "Selection review stopped.") }
        guard !items.isEmpty else { return (nil, skippedItems) }
        var plan=StorageRemovalPlan(id: Codec.id("storage-plan"), scanId: scan.id, rootPath: scan.rootPath, identity: scan.identity, createdAt: now(), expiresAt: now().addingTimeInterval(900), action: action, items: items)
        try StorageRemovalPlanRecords.save(&plan, store: store, progress: { current in
            progress(ExecutionProgress(stage: "preparing", processedCount: 0, itemCount: selected.count, path: current))
        })
        return (plan, skippedItems)
    }
    private func renamed(_ entry: FileEntry, to path: String) -> FileEntry { var copy=entry; copy.path=path; return copy }
    public func storageRemovalPlan(_ id: String) throws -> StorageRemovalPlan {
        try StorageRemovalPlanRecords.load(id, store: store)
    }
    public func executeStorageRemoval(planId: String, confirmedDigest: String, entryPoint: String, progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> ExecutionReceipt {
        let lease=try store.lock(); defer { lease.release() }
        let plan=try storageRemovalPlan(planId)
        guard plan.state == "ready" else { throw ShouError("already_executed", "This removal was already started.") }
        guard plan.expiresAt > now(), plan.digest == confirmedDigest else { throw ShouError("confirmation_required", "Removal confirmation expired or does not match.") }
        let scan=try storageScan(plan.scanId)
        guard plan.rootPath == scan.rootPath, plan.identity.sameObject(as: scan.identity),
              ["trash", "permanent"].contains(plan.action), !plan.items.isEmpty,
              Set(plan.items.map(\.path)).count == plan.items.count,
              StorageSelection.normalized(Set(plan.items.map(\.path))).count == plan.items.count else { throw ShouError("store_corrupt", "Removal scope is invalid.") }
        let workspace=Workspace(id: scan.id, rootRef: "space-analysis", path: scan.rootPath, identity: scan.identity, exclusions: [], addedAt: scan.createdAt)
        let items=plan.items.map { ItemReceipt(id: Codec.id("item"), originalPath: StorageRemovalPolicy.absolute(root: plan.rootPath, relative: $0.path), relativePath: $0.path, trashPath: nil, manifest: $0.manifest, state: "pending", allocatedBytesEstimate: $0.allocatedBytesEstimate, error: nil) }
        let began: (ExecutionReceipt) throws -> Void = { _ in
            try StorageRemovalPlanRecords.updateState(plan, store: self.store)
        }
        let context=try storageReviewContext(scan: scan)
        // The selected catalog may be this request's own evidence source. Read
        // only the selected identities before any mutation can remove it.
        var savedEntries=[String: FileEntry]()
        for item in plan.items {
            if let entry=try context.entry(item.path) { savedEntries[item.path]=entry }
        }
        let validate: (Int, [FileEntry]) throws -> String? = { index, manifest in
            guard try self.filesystem.analysisRootIdentity(scan.rootPath).sameObject(as: scan.identity) else { throw ShouError("access_expired", "Analysis root changed.") }
            let item=plan.items[index]
            if let reason=try self.storageRemovalReason(scan: scan, path: item.path, entry: savedEntries[item.path], context: context, checkDescendants: false) { return reason }
            guard let saved=savedEntries[item.path], manifest.first?.sameObject(as: saved) == true else {
                throw ShouError("plan_stale", "Selected item changed since confirmation.")
            }
            try FileManifestVerification.beforeMutation(filesystem: self.filesystem, path: items[index].originalPath,
                manifest: manifest, budget: ScanBudget(maxEntries: 1_000_000, maxSeconds: 600))
            if context.containsExclusion(path: item.path, manifest: manifest) { return "This selection contains excluded content." }
            return nil
        }
        let receipt: ExecutionReceipt
        if plan.action == "permanent" {
            receipt=try PermanentExecution.run(planId: plan.id, workspace: workspace, items: items, entryPoint: entryPoint, store: store, filesystem: filesystem, now: now(), operation: "storage_permanent_removal", progress: progress, didBegin: began, validateItem: validate)
        } else {
            receipt=try TrashExecution.run(planId: plan.id, workspace: workspace, items: items, entryPoint: entryPoint, store: store, filesystem: filesystem, now: now(), operation: "storage_removal", progress: progress, didBegin: began, validateItem: { index in try validate(index, plan.items[index].manifest) })
        }
        try StorageRemovalPlanRecords.updateState(plan, store: store, state: receipt.state)
        return receipt
    }
}
