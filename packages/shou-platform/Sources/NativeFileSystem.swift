import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
public struct NativeFileSystem: PlatformFileSystem {
    private let readWorkerExecutable: URL?
    public var platform: String {
        #if os(macOS)
        "macos"
        #else
        "linux"
        #endif
    }
    public var supportsTrash: Bool { trashUnavailableReason == nil }
    public var trashUnavailableReason: String? {
        #if os(macOS)
        // API availability is separate from permission to enumerate the Trash.
        // trashItem reports actual per-target access; never pre-read the whole Trash.
        nil
        #else
        "Native Trash is unavailable on this platform."
        #endif
    }
    public init(readWorkerExecutable: URL? = nil) { self.readWorkerExecutable=readWorkerExecutable }
    public func locationAvailability(_ path: String) -> LocationAvailability {
        // Availability needs only directory metadata. Foundation attributes can
        // query extended attributes and stall discovery of known locations.
        var metadata=stat()
        if lstat(path, &metadata) == 0 {
            return metadata.st_mode & S_IFMT == S_IFDIR ? .available : .unavailable("The scan location is a symbolic link or is not a directory.")
        }
        let failure=errno
        if failure == ENOENT || failure == ENOTDIR { return .missing }
        return .unavailable("The scan location could not be inspected.")
    }
    public func rootIdentity(_ path: String) throws -> FileEntry {
        if let readWorkerExecutable {
            return try NativeReadClient(executable: readWorkerExecutable).rootIdentity(path)
        }
        // Identity needs metadata and search access, not permission to enumerate.
        let fd = try SecurePaths.directory(path, readFinalDirectory: false); defer { close(fd) }
        let normalized = "/" + (try SecurePaths.components(path)).joined(separator: "/")
        var metadata=stat()
        guard fstat(fd, &metadata) == 0 else { throw SecurePaths.failure("Inspect workspace", path: path) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let blocked = ["/", home, "/Users", "/System", "/Library", "/Applications", "/Volumes", "/private", "/usr", "/bin", "/sbin", "/etc", "/dev"]
        let data = LocalRecordStore.defaultDirectory.path
        guard !blocked.contains(normalized), !["/System/", "/usr/", "/Library/", "/Applications/", "/bin/", "/sbin/", "/dev/"].contains(where: normalized.hasPrefix),
              !normalized.hasPrefix(home + "/.Trash"), !normalized.hasPrefix(data),
              !normalized.hasPrefix(home + "/Library/Mobile Documents"), !normalized.hasPrefix(home + "/Library/CloudStorage"), metadata.st_uid == getuid() else {
            throw ShouError("permission_denied", "This root is protected or is not owned by the current user.", details: ["path": path])
        }
        if let local = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal, !local {
            throw ShouError("capability_unavailable", "Network workspaces are outside the supported execution scope.")
        }
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        return SecurePaths.entry(metadata, path: ".")
    }
    public func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        try inspect(path, budget: budget, cancelled: cancelled, progress: { _ in })
    }
    public func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        if let readWorkerExecutable {
            return try NativeReadClient(executable: readWorkerExecutable).inspect(path, rules: nil, budget: budget, cancelled: cancelled, progress: progress)
        }
        return try inspectTree(path, cleanupRules: nil, budget: budget, cancelled: cancelled, progress: progress)
    }
    public func inspectCleanup(_ path: String, rules: [CleanupRule], budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        if let readWorkerExecutable {
            return try NativeReadClient(executable: readWorkerExecutable).inspect(path, rules: rules, budget: budget, cancelled: cancelled, progress: progress)
        }
        return try inspectTree(path, cleanupRules: rules, budget: budget, cancelled: cancelled, progress: progress)
    }
    private func inspectTree(_ path: String, cleanupRules: [CleanupRule]?, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        let root = try SecurePaths.directory(path); defer { close(root) }
        var metadata=stat()
        guard fstat(root, &metadata) == 0 else { throw SecurePaths.failure("Inspect root", path: path) }
        let device = metadata.st_dev
        var entries: [FileEntry] = [SecurePaths.entry(metadata, path: ".")], issues: [String] = []
        var completedPaths=Set<String>()
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let caseSensitive=values?.volumeSupportsCaseSensitiveNames ?? true
        let prepared=(cleanupRules ?? []).flatMap { rule in rule.match.relativePatterns.map { (PathPattern.Compiled($0, caseSensitive: caseSensitive), rule.scope.maxDepth) } }
        let markerNames=Set((cleanupRules ?? []).flatMap { $0.match.projectMarkers?.allOf ?? [] } + ["Package.swift", "workspace-state.json"])
        let prunedNames: Set<String>=[".git", ".hg", ".svn", ".ssh", ".gnupg", ".shou"]
        var visitedCount=1
        let deadline=Date().addingTimeInterval(budget.maxSeconds)
        var stopped=false
        var lastReported=Date.distantPast
        progress(ScanProgress(stage: "scanning", entryCount: 0))
        func visit(_ descriptor: Int32, _ relative: String, _ depth: Int, measuring: Bool) {
            if stopped { return }
            let initialIssueCount=issues.count
            if cancelled() { issues.append("cancelled"); stopped=true; return }
            if visitedCount >= budget.maxEntries || Date() > deadline || depth > budget.maxDepth { issues.append("resource_limit"); stopped=true; return }
            do {
                var before=stat()
                guard fstat(descriptor, &before) == 0 else { throw SecurePaths.failure("Inspect directory", path: relative) }
                for name in try SecurePaths.names(descriptor) {
                    if stopped { break }
                    if cancelled() || Date() > deadline || visitedCount >= budget.maxEntries { issues.append(cancelled() ? "cancelled" : "resource_limit"); stopped=true; break }
                    let child = relative.isEmpty ? name : relative + "/" + name
                    if !measuring && prunedNames.contains(name.lowercased()) { continue }
                    var info=stat()
                    guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { issues.append("unreadable: " + child); continue }
                    visitedCount += 1
                    #if canImport(Darwin)
                    if info.st_flags & UInt32(SF_DATALESS) != 0 { issues.append("cloud_placeholder: " + child); continue }
                    #endif
                    guard info.st_dev == device else { issues.append("cross_filesystem: " + child); continue }
                    let directory=info.st_mode & S_IFMT == S_IFDIR
                    let parts=(caseSensitive ? child : child.lowercased()).split(separator: "/").map(String.init)
                    let target=measuring || (directory && prepared.contains { parts.count <= $0.1 && $0.0.matches(parts) })
                    let discover=directory && (target || prepared.contains { parts.count < $0.1 && $0.0.couldMatchDescendant(of: parts) })
                    if measuring || target || discover || markerNames.contains(name) { entries.append(SecurePaths.entry(info, path: child)) }
                    if visitedCount % 128 == 0 && Date().timeIntervalSince(lastReported) >= 0.25 {
                        progress(ScanProgress(stage: "scanning", entryCount: visitedCount, currentPath: child)); lastReported=Date()
                    }
                    if directory && (measuring || discover) {
                        let sub = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard sub >= 0 else { issues.append("unreadable_directory: " + child); continue }
                        var opened=stat()
                        if fstat(sub, &opened) == 0 && opened.st_ino == info.st_ino && opened.st_dev == info.st_dev { visit(sub, child, depth+1, measuring: target) }
                        else { issues.append("changed_directory: " + child) }
                        close(sub)
                    }
                }
                var after=stat()
                if fstat(descriptor, &after) != 0 || SecurePaths.entry(before, path: ".") != SecurePaths.entry(after, path: ".") { issues.append("changed_during_scan: " + relative) }
                if measuring && issues.count == initialIssueCount && !stopped {
                    let completePath=relative.isEmpty ? "." : relative
                    for child in completedPaths where completePath == "." || child.hasPrefix(completePath + "/") { completedPaths.remove(child) }
                    completedPaths.insert(completePath)
                }
            } catch { issues.append("\(relative): \(error)") }
        }
        visit(root, "", 0, measuring: cleanupRules == nil)
        progress(ScanProgress(stage: "scanning", entryCount: visitedCount))
        return TreeSnapshot(entries: entries.sorted { $0.path < $1.path }, complete: cleanupRules == nil && issues.isEmpty, issues: issues, caseSensitive: caseSensitive, completedPaths: completedPaths.sorted(), discoveryComplete: cleanupRules == nil ? nil : issues.isEmpty)
    }
    public func availableBytes(_ path: String) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: path)[.systemFreeSize] as? NSNumber)?.int64Value
    }
    public func isTrashLocation(_ path: String) -> Bool {
        #if os(macOS)
        let item=URL(fileURLWithPath: path)
        guard let trash=try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: item, create: false),
              item.deletingLastPathComponent().standardizedFileURL.path == trash.standardizedFileURL.path,
              let descriptor=try? SecurePaths.directory(trash.path, readFinalDirectory: false) else { return false }
        defer { close(descriptor) }
        var metadata=stat()
        return fstat(descriptor, &metadata) == 0 && metadata.st_uid == getuid()
        #else
        return false
        #endif
    }
    private func verify(_ path: String, _ expected: [FileEntry], trashReceipt: Bool = false) throws {
        let current = try inspect(path, budget: ScanBudget(maxEntries: max(100_000, expected.count + 1), maxSeconds: 180), cancelled: { Task.isCancelled })
        guard current.complete, current.entries.count == expected.count,
              zip(current.entries, expected).allSatisfy({ observed, saved in
                  observed == saved || (trashReceipt && observed.matchesTrashRoot(as: saved))
              }) else { throw ShouError("plan_stale", "The target or its descendants changed.", details: ["path": path]) }
    }
    public func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult {
        #if os(macOS)
        guard let original=expected.first(where: { $0.path == "." }), original.kind == "directory" else {
            throw ShouError("invalid_argument", "A complete directory manifest is required before moving to Trash.")
        }
        let (parentFD, name)=try SecurePaths.parent(path); defer { close(parentFD) }
        let targetFD=openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard targetFD >= 0 else { throw SecurePaths.failure("Open Trash target without following links", path: path) }
        defer { close(targetFD) }
        var parent=stat(), pinned=stat()
        guard fstat(parentFD, &parent) == 0, fstat(targetFD, &pinned) == 0,
              SecurePaths.entry(pinned, path: ".") == original else {
            throw ShouError("plan_stale", "The Trash target changed before verification.")
        }
        try verify(path, expected)
        let (currentParentFD, currentName)=try SecurePaths.parent(path); defer { close(currentParentFD) }
        var currentParent=stat(), currentTarget=stat()
        guard currentName == name, fstat(currentParentFD, &currentParent) == 0,
              SecurePaths.entry(parent, path: ".").sameObject(as: SecurePaths.entry(currentParent, path: ".")),
              fstatat(parentFD, name, &currentTarget, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(currentTarget, path: ".") == original else {
            throw ShouError("plan_stale", "The Trash target or its parent changed before the system operation.")
        }
        var destination: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &destination)
        guard let destination, destination.isFileURL, let destinationPath=destination.path else {
            throw ShouError("io_error", "Trash operation did not report its destination. Inspect the system Trash before retrying.")
        }
        let tree = try? inspect(destinationPath, budget: ScanBudget(maxEntries: max(100_000, expected.count + 1), maxSeconds: 180), cancelled: { false })
        let moved = tree?.entries.first { $0.path == "." }
        var verified = tree?.complete == true && moved.map { original.sameObject(as: $0) } == true && isTrashLocation(destinationPath)
        if let tree {
            // Moving a directory changes its root ctime, but must preserve every descendant.
            let descendants = tree.entries.filter { $0.path != "." }
            verified = verified && descendants == expected.filter { $0.path != "." }
        }
        return TrashResult(path: destinationPath, manifest: tree?.entries ?? [], verified: verified)
        #else
        throw ShouError("capability_unavailable", "Native Trash has not been implemented on this platform.")
        #endif
    }
    public func restore(_ path: String, to destination: String, expected: [FileEntry]) throws {
        try verify(path, expected, trashReceipt: true)
        let (sourceFD, sourceName) = try SecurePaths.parent(path); defer { close(sourceFD) }
        let (destinationFD, destinationName) = try SecurePaths.parent(destination); defer { close(destinationFD) }
        #if canImport(Darwin)
        guard renameatx_np(sourceFD, sourceName, destinationFD, destinationName, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw ShouError("restore_conflict", "Restore destination already exists; nothing was overwritten.") }
            throw SecurePaths.failure("Restore without overwriting", path: destination)
        }
        #else
        throw ShouError("capability_unavailable", "Atomic no-overwrite restoration is unavailable on this platform.")
        #endif
    }
    public func purge(_ path: String, expected: [FileEntry]) throws {
        try verify(path, expected, trashReceipt: true)
        // Only known manifest entries are removed. New entries cause rmdir to fail.
        for entry in expected.sorted(by: { $0.path.split(separator: "/").count == $1.path.split(separator: "/").count ? $0.path > $1.path : $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }) where entry.path != "." {
            if Task.isCancelled { throw ShouError("cancelled", "Permanent removal cancelled; inspect the partial result.") }
            let full = path + "/" + entry.path
            let (fd, name) = try SecurePaths.parent(full); defer { close(fd) }
            var info=stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecurePaths.failure("Inspect receipt entry", path: full) }
            let current = SecurePaths.entry(info, path: entry.path)
            guard current.sameObject(as: entry), entry.kind == "directory" || current == entry else { throw ShouError("plan_stale", "Receipt entry changed; permanent removal stopped.") }
            guard unlinkat(fd, name, entry.kind == "directory" ? AT_REMOVEDIR : 0) == 0 else { throw SecurePaths.failure("Remove receipt entry", path: full) }
        }
        let (fd, name) = try SecurePaths.parent(path); defer { close(fd) }
        var info=stat()
        guard let original = expected.first(where: { $0.path == "." }), fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(info, path: ".").sameObject(as: original) else { throw ShouError("plan_stale", "Receipt root changed.") }
        guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw SecurePaths.failure("Remove empty receipt directory", path: path) }
    }
}
#endif
