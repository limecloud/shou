import Foundation
import ShouCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
public struct NativeFileSystem: PlatformFileSystem {
    private let readWorkerExecutable: URL?
    private let scanPrivacyOverride: ScanPrivacyPolicy?
    var scanPrivacyPolicy: ScanPrivacyPolicy { scanPrivacyOverride ?? .current }
    var storageReadWorkerExecutable: URL? { readWorkerExecutable }
    private let applicationRoots: [String]
    private let applicationRecycler: (any ApplicationRecycling)?
    public var platform: String {
        #if os(macOS)
        "macos"
        #else
        "linux"
        #endif
    }
    // Keep the storage-catalog witnesses on the conformance declaration. Swift otherwise may
    // bind a protocol existential to PlatformFileSystem's fallback implementation when the
    // streaming methods live in a later source-file extension.
    public var supportsStorageCatalog: Bool { true }
    public var verifiesMutationManifest: Bool { true }
    public var maximumConcurrentReadOperations: Int { readWorkerExecutable == nil ? 4 : NativeReadClient.maximumConcurrentChildren }
    public func measureStorage(_ path: String, catalog: URL, cancelled: @Sendable () -> Bool,
                               progress: @Sendable (ScanProgress) -> Void) throws -> StorageMeasurement {
        try withoutActuallyEscaping(cancelled) { escapingCancelled in
            try withoutActuallyEscaping(progress) { escapingProgress in
                try measureStorageImpl(path, catalog: catalog, cancelled: escapingCancelled, progress: escapingProgress)
            }
        }
    }
    public var supportsTrash: Bool { trashUnavailableReason == nil }
    public var supportsAuthorizedApplicationTrash: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
    public var trashUnavailableReason: String? {
        #if os(macOS)
        // API availability is separate from permission to enumerate the Trash.
        // trashItem reports actual per-target access; never pre-read the whole Trash.
        nil
        #else
        "Native Trash is unavailable on this platform."
        #endif
    }
    public init(readWorkerExecutable: URL? = nil, applicationRoots: [String]? = nil, scanPrivacyPolicy: ScanPrivacyPolicy? = nil, applicationRecycler: (any ApplicationRecycling)? = nil) {
        self.readWorkerExecutable=readWorkerExecutable
        self.scanPrivacyOverride=scanPrivacyPolicy
        self.applicationRoots=applicationRoots ?? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path, "/Applications"]
        self.applicationRecycler=applicationRecycler
    }
    var usesSystemAuthorization: Bool {
        #if os(macOS)
        getuid() != 0 && supportsSystemAuthorization && NativeSystemAuthorization.shared.administratorState == .authorized
        #else
        false
        #endif
    }
    func directoryIdentity(_ path: String) throws -> FileEntry {
        #if os(macOS)
        if usesSystemAuthorization {
            let reply=try NativeSystemAuthorization.shared.perform(.pathIdentity, path: path)
            guard let identity=reply.identity, identity.kind == "directory" else { throw ShouError("plan_stale", "The selected directory is unavailable.") }
            return identity
        }
        #endif
        let descriptor=try SecurePaths.directory(path, readFinalDirectory: false)
        defer { close(descriptor) }
        var metadata=stat()
        guard fstat(descriptor, &metadata) == 0 else { throw SecurePaths.failure("Inspect directory", path: path) }
        return SecurePaths.entry(metadata, path: ".")
    }
    public var supportsAuthorizedApplicationPermanentRemoval: Bool { supportsSystemAuthorization }
    private var supportsSystemAuthorization: Bool {
        #if os(macOS)
        return (try? NativeSystemAuthorization.workerExecutable()) != nil
        #else
        return false
        #endif
    }
    public func applicationNeedsAuthorization(_ path: String) -> Bool { needsAuthorizationForParent(path) }
    public func applicationShortcut(_ path: String) throws -> ApplicationShortcutSnapshot {
        #if os(macOS)
        if usesSystemAuthorization {
            let reply=try NativeSystemAuthorization.shared.perform(.inspectApplicationShortcut, path: path)
            guard let snapshot=reply.applicationShortcut, snapshot.currentUser == getuid() else { throw AuthorizationChannel.failure() }
            return snapshot
        }
        return try NativeApplicationShortcut.snapshot(path, roots: applicationRoots, uid: getuid())
        #else
        throw ShouError("capability_unavailable", "Broken application shortcut cleanup is unavailable on this filesystem.")
        #endif
    }
    private func needsAuthorizationForParent(_ path: String) -> Bool {
        #if os(macOS)
        guard geteuid() != 0 else { return false }
        guard let (parent, _)=try? SecurePaths.parent(path) else { return true }
        defer { close(parent) }
        return faccessat(parent, ".", W_OK | X_OK, 0) != 0
        #else
        return false
        #endif
    }
    #if os(macOS)
    func removalNeedsAuthorization(_ path: String, expected: [FileEntry]) -> Bool {
        if needsAuthorizationForParent(path) || expected.contains(where: { $0.owner == 0 }) { return true }
        // Removing directory contents needs write/search access to each parent,
        // even when every entry is owned by the caller and readable for review.
        return expected.contains { entry in
            guard entry.kind == "directory" else { return false }
            let directory=entry.path == "." ? path : path + "/" + entry.path
            return access(directory, W_OK | X_OK) != 0
        }
    }
    #endif
    public func applicationParentIdentity(_ path: String) throws -> FileEntry {
        let components=try SecurePaths.components(path)
        guard "/" + components.joined(separator: "/") == path,
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              applicationRoots.contains(where: { root in
                  if path == root { return true }
                  guard path.hasPrefix(root + "/") else { return false }
                  let relative=path.dropFirst(root.count + 1).split(separator: "/")
                  return relative.count <= ApplicationCatalogOptions.maxContainerDepth && !relative.contains { $0.lowercased().hasSuffix(".app") }
              }) else { throw ShouError("permission_denied", "Application parent is outside supported installation directories.") }
        #if os(macOS)
        if getuid() != 0, NativeSystemAuthorization.shared.administratorState == .authorized {
            let reply=try NativeSystemAuthorization.shared.perform(.applicationParentIdentity, path: path)
            guard let identity=reply.identity, identity.path == ".", identity.kind == "directory" else { throw AuthorizationChannel.failure() }
            return identity
        }
        #endif
        let descriptor=try SecurePaths.directory(path, readFinalDirectory: false)
        defer { close(descriptor) }
        var metadata=stat()
        guard fstat(descriptor, &metadata) == 0 else { throw SecurePaths.failure("Inspect application parent", path: path) }
        guard (try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey])).volumeIsLocal == true else {
            throw ShouError("capability_unavailable", "Application removal requires a local installation directory.")
        }
        return SecurePaths.entry(metadata, path: ".")
    }
    public func locationAvailability(_ path: String) -> LocationAvailability {
        #if os(macOS)
        if let value=authorizedAvailability(path,directoryOnly:true) { return value }
        #endif
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
    public func targetAvailability(_ path: String) -> LocationAvailability {
        #if os(macOS)
        if let value=authorizedAvailability(path,directoryOnly:false) { return value }
        #endif
        do {
            let (parent, name)=try SecurePaths.parent(path)
            defer { close(parent) }
            var metadata=stat()
            if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                let type=metadata.st_mode & S_IFMT
                return type == S_IFREG || type == S_IFDIR ? .available : .unavailable("The target is a link or an unsupported file type.")
            }
            return errno == ENOENT ? .missing : .unavailable("The target could not be inspected.")
        } catch { return .unavailable(error.localizedDescription) }
    }
    public func rootIdentity(_ path: String) throws -> FileEntry {
        if let readWorkerExecutable, !usesSystemAuthorization {
            return try NativeReadClient(executable: readWorkerExecutable).rootIdentity(path)
        }
        try scanPrivacyPolicy.checkRoot(path)
        // Identity needs metadata and search access, not permission to enumerate.
        let normalized = "/" + (try SecurePaths.components(path)).joined(separator: "/")
        let identity=try directoryIdentity(path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let blocked = ["/", home, "/Users", "/System", "/Library", "/Applications", "/Volumes", "/private", "/usr", "/bin", "/sbin", "/etc", "/dev"]
        let data = LocalRecordStore.defaultDirectory.path
        guard !blocked.contains(normalized), !["/System/", "/usr/", "/Library/", "/Applications/", "/bin/", "/sbin/", "/dev/"].contains(where: normalized.hasPrefix),
              !normalized.hasPrefix(home + "/.Trash"), !normalized.hasPrefix(data),
              !normalized.hasPrefix(home + "/Library/Mobile Documents"), !normalized.hasPrefix(home + "/Library/CloudStorage"), identity.owner == getuid() else {
            throw ShouError("permission_denied", "This root is protected or is not owned by the current user.", details: ["path": path])
        }
        if let local = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal, !local {
            throw ShouError("capability_unavailable", "Network workspaces are outside the supported execution scope.")
        }
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        return identity
    }
    public func analysisRootIdentity(_ path: String) throws -> FileEntry {
        let identity=try directoryIdentity(path)
        guard (try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey])).volumeIsLocal == true else {
            throw ShouError("capability_unavailable", "Space analysis requires a local volume.")
        }
        return identity
    }
    public func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        try inspect(path, budget: budget, cancelled: cancelled, progress: { _ in })
    }
    public func inspectTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        #if os(macOS)
        if getuid() != 0, NativeSystemAuthorization.shared.administratorState == .authorized,
           (try? NativeSystemAuthorizationWorker.validateApplicationPath(path, roots: applicationRoots, verifyFilesystem: false)) != nil {
            let reply=try NativeSystemAuthorization.shared.perform(.inspectApplication, path: path, budget: budget)
            guard let snapshot=reply.snapshot else { throw AuthorizationChannel.failure() }
            return snapshot
        }
        #endif
        #if os(macOS)
        if let result=try authorizedInspection(path, operation: .inspectPath, budget: budget, cancelled: cancelled, progress: { _ in }) { return result }
        #endif
        return try inspectTarget(path, budget: budget, cancelled: cancelled, useWorker: true)
    }
    public func inspectStorageTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        try inspectStorageTarget(path, budget: budget, cancelled: cancelled, progress: { _ in })
    }
    public func inspectStorageTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        #if os(macOS)
        if let result=try authorizedInspection(path, operation: .inspectPath, budget: budget, cancelled: cancelled, progress: progress) { return result }
        #endif
        return try inspectTarget(path, budget: budget, cancelled: cancelled, useWorker: true, largeFile: true, progress: progress)
    }
    public func inspectTrashTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        guard isTrashLocation(path) else { throw ShouError("permission_denied", "Only an exact system Trash item can be inspected.") }
        // Inspect the recorded direct child, never unrelated Trash contents.
        // Actual OS permissions and no-follow traversal remain in force.
        return try inspectTarget(path, budget: budget, cancelled: cancelled, useWorker: false, largeFile: true,
            privacyPolicy: ScanPrivacyPolicy(status: .notRequired, home: scanPrivacyPolicy.home))
    }
    private func inspectTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool, useWorker: Bool, largeFile: Bool = false, privacyPolicy: ScanPrivacyPolicy? = nil, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> TreeSnapshot {
        let (parent, name)=try SecurePaths.parent(path, cancelled: cancelled)
        defer { close(parent) }
        var metadata=stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecurePaths.failure("Inspect target", path: path) }
        if metadata.st_mode & S_IFMT == S_IFDIR {
            if useWorker { return try inspect(path, budget: budget, cancelled: cancelled, progress: progress) }
            return try inspectTree(path, cleanupRules: nil, budget: budget, cancelled: cancelled, progress: progress, privacyPolicy: privacyPolicy)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw ShouError("invalid_argument", "Only a regular file or directory can be inspected as a target.") }
        guard (1...1_000_000).contains(budget.maxEntries), budget.maxSeconds.isFinite, (1...600).contains(budget.maxSeconds), (1...128).contains(budget.maxDepth) else { throw ShouError("resource_limit", "The target read budget was exhausted.") }
        let descriptor=openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SecurePaths.failure("Open target without following links", path: path) }
        defer { close(descriptor) }
        var opened=stat(), current=stat()
        var expected=SecurePaths.entry(metadata, path: ".")
        guard fstat(descriptor, &opened) == 0, fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(opened, path: ".") == expected, SecurePaths.entry(current, path: ".") == expected else {
            throw ShouError("plan_stale", "The file changed while inspecting its metadata.")
        }
        if cancelled() { throw ShouError("cancelled", "Scan cancelled.") }
        let deadline=ContinuousClock.now.advanced(by: .seconds(budget.maxSeconds))
        let contentDigest: String
        if largeFile {
            #if canImport(CryptoKit)
            var hasher=SHA256(), buffer=[UInt8](repeating: 0, count: 1_048_576)
            while true {
                if cancelled() { throw ShouError("cancelled", "Scan cancelled.") }
                guard ContinuousClock.now < deadline else { throw ShouError("resource_limit", "The target read budget was exhausted.") }
                let count=buffer.withUnsafeMutableBytes { raw in
                    #if canImport(Darwin)
                    Darwin.read(descriptor, raw.baseAddress, raw.count)
                    #else
                    Glibc.read(descriptor, raw.baseAddress, raw.count)
                    #endif
                }
                if count == 0 { break }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SecurePaths.failure("Read selected file", path: path) }
                hasher.update(data: Data(buffer.prefix(count)))
            }
            contentDigest="sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
            #else
            throw ShouError("capability_unavailable", "Streaming file verification is unavailable on this platform.")
            #endif
        } else {
            let bytes=try NativeDefinitionFiles.bytes(directory: parent, name: name, path: path, maximumBytes: 16_777_216, deadline: deadline, cancelled: cancelled)
            contentDigest=Digest.sha256(bytes)
        }
        guard fstat(descriptor, &opened) == 0, SecurePaths.entry(opened, path: ".") == expected else {
            throw ShouError("plan_stale", "The file changed while reading its content digest.")
        }
        if cancelled() { throw ShouError("cancelled", "Scan cancelled.") }
        expected.contentDigest=contentDigest
        let values=try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return TreeSnapshot(entries: [expected], complete: true, issues: [], caseSensitive: values?.volumeSupportsCaseSensitiveNames ?? true)
    }
    public func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        #if os(macOS)
        if let result=try authorizedInspection(path, operation: .inspectPath, budget: budget, cancelled: cancelled, progress: progress) { return result }
        #endif
        if let readWorkerExecutable {
            return try NativeReadClient(executable: readWorkerExecutable).inspect(path, rules: nil, budget: budget, cancelled: cancelled, progress: progress)
        }
        return try inspectTree(path, cleanupRules: nil, budget: budget, cancelled: cancelled, progress: progress)
    }
    public func inspectCleanup(_ path: String, rules: [CleanupRule], budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        #if os(macOS)
        if let result=try authorizedInspection(path, operation: .inspectCleanupPath, budget: budget, rules: rules, cancelled: cancelled, progress: progress) { return result }
        #endif
        if let readWorkerExecutable {
            return try NativeReadClient(executable: readWorkerExecutable).inspect(path, rules: rules, budget: budget, cancelled: cancelled, progress: progress)
        }
        return try inspectCleanupTree(path, rules: rules, budget: budget, cancelled: cancelled, progress: progress)
    }
    func measureCleanupTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        try inspectTree(path, cleanupRules: nil, budget: budget, cancelled: cancelled, progress: progress)
    }
    private func inspectTree(_ path: String, cleanupRules: [CleanupRule]?, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void, privacyPolicy: ScanPrivacyPolicy? = nil) throws -> TreeSnapshot {
        let privacy=privacyPolicy ?? scanPrivacyPolicy
        try privacy.checkRoot(path)
        let root = try SecurePaths.directory(path, cancelled: cancelled); defer { close(root) }
        var metadata=stat()
        guard fstat(root, &metadata) == 0 else { throw SecurePaths.failure("Inspect root", path: path) }
        let device = metadata.st_dev
        var entries: [FileEntry] = [SecurePaths.entry(metadata, path: ".")], issues: [String] = []
        var completedPaths=[String]()
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
            let completedStart=completedPaths.count
            if cancelled() { issues.append("cancelled"); stopped=true; return }
            if visitedCount >= budget.maxEntries || Date() > deadline || depth > budget.maxDepth { issues.append("resource_limit"); stopped=true; return }
            do {
                var before=stat()
                guard fstat(descriptor, &before) == 0 else { throw SecurePaths.failure("Inspect directory", path: relative) }
                func checkpoint() throws {
                    if cancelled() { throw ShouError("cancelled", "Scan cancelled.") }
                    if stopped || Date() > deadline || visitedCount >= budget.maxEntries { throw ShouError("resource_limit", "The target read budget was exhausted.") }
                }
                func consume(_ batch: [NativeDirectoryEntry]) throws {
                for item in batch {
                    let name=item.name
                    if stopped { break }
                    if cancelled() || Date() > deadline || visitedCount >= budget.maxEntries { issues.append(cancelled() ? "cancelled" : "resource_limit"); stopped=true; break }
                    let child = relative.isEmpty ? name : relative + "/" + name
                    if !measuring && prunedNames.contains(name.lowercased()) { continue }
                    var observed: FileEntry, flags=item.flags
                    if let metadata=item.entry, metadata.kind == "file" {
                        observed=metadata; observed.path=child
                    } else {
                        var info=stat()
                        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { issues.append("unreadable: " + child); continue }
                        observed=SecurePaths.entry(info, path: child)
                        #if canImport(Darwin)
                        flags=info.st_flags
                        #endif
                    }
                    visitedCount += 1
                    #if canImport(Darwin)
                    if flags & UInt32(SF_DATALESS) != 0 { issues.append("cloud_placeholder: " + child); continue }
                    #endif
                    guard observed.device == UInt64(device) else { issues.append("cross_filesystem: " + child); continue }
                    let directory=observed.kind == "directory"
                    let target: Bool, discover: Bool
                    if measuring {
                        target=true; discover=directory
                    } else if directory {
                        let parts=(caseSensitive ? child : child.lowercased()).split(separator: "/").map(String.init)
                        target=prepared.contains { parts.count <= $0.1 && $0.0.matches(parts) }
                        discover=target || prepared.contains { parts.count < $0.1 && $0.0.couldMatchDescendant(of: parts) }
                    } else { target=false; discover=false }
                    if measuring || target || discover || markerNames.contains(name) { entries.append(observed) }
                    if visitedCount % 128 == 0 && Date().timeIntervalSince(lastReported) >= 0.25 {
                        progress(ScanProgress(stage: "scanning", entryCount: visitedCount, currentPath: child)); lastReported=Date()
                    }
                    if directory && (measuring || discover) {
                        if privacy.requiresAuthorization(path + "/" + child) {
                            issues.append(privacy.coverageCode(path + "/" + child) + ": " + child); continue
                        }
                        let sub = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard sub >= 0 else { issues.append("unreadable_directory: " + child); continue }
                        var opened=stat()
                        if fstat(sub, &opened) == 0 && UInt64(opened.st_ino) == observed.inode && UInt64(opened.st_dev) == observed.device { visit(sub, child, depth+1, measuring: target) }
                        else { issues.append("changed_directory: " + child) }
                        close(sub)
                    }
                }
                }
                let truncated: Bool
                #if canImport(Darwin)
                truncated=try NativeDirectoryReader.enumerate(descriptor, limit: max(0, budget.maxEntries - visitedCount),
                    deadline: .now.advanced(by: .seconds(max(0, deadline.timeIntervalSinceNow))), cancelled: cancelled, checkpoint: checkpoint, consume: consume)
                #else
                let listing=try NativeDefinitionFiles.names(descriptor, limit: max(0, budget.maxEntries - visitedCount),
                    deadline: .now.advanced(by: .seconds(max(0, deadline.timeIntervalSinceNow))), cancelled: cancelled)
                try consume(listing.names.map { NativeDirectoryEntry(name: $0, entry: nil, flags: 0) })
                truncated=listing.truncated
                #endif
                if truncated { issues.append("resource_limit"); stopped=true }
                var after=stat()
                if fstat(descriptor, &after) != 0 || SecurePaths.entry(before, path: ".") != SecurePaths.entry(after, path: ".") { issues.append("changed_during_scan: " + relative) }
                if measuring && issues.count == initialIssueCount && !stopped {
                    let completePath=relative.isEmpty ? "." : relative
                    // Traversal is depth-first, so only this frame's trailing
                    // results are descendants. Do not rescan completed siblings
                    // for each directory in a wide build-cache tree.
                    completedPaths.removeSubrange(completedStart...)
                    completedPaths.append(completePath)
                }
            } catch let error as ShouError where ["cancelled", "resource_limit"].contains(error.code) {
                issues.append(error.code); stopped=true
            } catch { issues.append("\(relative): \(error)") }
        }
        visit(root, "", 0, measuring: cleanupRules == nil)
        progress(ScanProgress(stage: "analysis", entryCount: visitedCount, currentPath: path, limitReached: issues.contains("resource_limit")))
        return TreeSnapshot(entries: entries.sorted { $0.path < $1.path }, complete: cleanupRules == nil && issues.isEmpty, issues: issues, caseSensitive: caseSensitive, completedPaths: completedPaths.sorted(), discoveryComplete: cleanupRules == nil ? nil : issues.isEmpty)
    }
    public func availableBytes(_ path: String) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: path)[.systemFreeSize] as? NSNumber)?.int64Value
    }
    public func isTrashLocation(_ path: String) -> Bool {
        #if os(macOS)
        let item=URL(fileURLWithPath: path)
        // A restored or removed child no longer exists. Resolve its volume from
        // the existing parent so read-only history checks can still prove absence.
        guard let trash=try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: item.deletingLastPathComponent(), create: false),
              item.deletingLastPathComponent().standardizedFileURL.path == trash.standardizedFileURL.path,
              let descriptor=try? SecurePaths.directory(trash.path, readFinalDirectory: false, cancelled: { false }) else { return false }
        defer { close(descriptor) }
        var metadata=stat()
        return fstat(descriptor, &metadata) == 0 && metadata.st_uid == getuid()
        #else
        return false
        #endif
    }
    private func verify(_ path: String, _ expected: [FileEntry], trashReceipt: Bool = false,
                        cancelled: @Sendable () -> Bool = { false }, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws {
        let current = try inspectMutationTarget(path, entryCount: expected.count, cancelled: cancelled, progress: progress)
        if cancelled() { throw ShouError("cancelled", "Scan cancelled.") }
        guard current.complete, FileManifestVerification.matches(current.entries, expected, allowingTrashRootChanges: trashReceipt) else {
            throw ShouError("plan_stale", "The target or its descendants changed.", details: ["path": path])
        }
    }
    private func inspectMutationTarget(_ path: String, entryCount: Int, cancelled: @Sendable () -> Bool = { false }, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> TreeSnapshot {
        // Once the caller journals an operation, finish its native verification
        // without delegating to a cancellable scan worker. Stop between items.
        // The broad-scan policy deliberately skips Trash without FDA. A recorded
        // direct child needs an actual OS access attempt to verify/restore it;
        // this does not enumerate Trash or bypass filesystem permissions.
        let budget=ScanBudget(maxEntries: max(100_000, entryCount + 1), maxSeconds: 180)
        if isTrashLocation(path) {
            return try inspectTarget(path, budget: budget, cancelled: cancelled, useWorker: false, largeFile: true,
                privacyPolicy: ScanPrivacyPolicy(status: .notRequired, home: scanPrivacyPolicy.home), progress: progress)
        }
        return try inspectTarget(path, budget: budget, cancelled: cancelled, useWorker: false, largeFile: true, progress: progress)
    }
    public func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult {
        #if os(macOS)
        if getuid() != 0, supportsSystemAuthorization, applicationNeedsAuthorization(path) {
            _ = try FileManager.default.url(for:.trashDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            let reply=try NativeSystemAuthorization.shared.perform(.trashPath,path:path,manifest:expected,
                fullDiskAccess:[.available,.notRequired].contains(scanPrivacyPolicy.status))
            guard let destination=reply.path, let snapshot=reply.snapshot else { throw AuthorizationChannel.failure() }
            return TrashResult(path:destination,manifest:snapshot.entries,verified:snapshot.complete && FileManifestVerification.matches(snapshot.entries,expected,allowingTrashRootChanges:true))
        }
        #endif
        return try moveToTrashChecked(path,expected:expected,applicationRecycler:nil)
    }
    public func moveApplicationToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult {
        #if os(macOS)
        let components=try SecurePaths.components(path)
        guard "/" + components.joined(separator:"/") == path, path.lowercased().hasSuffix(".app"),
              path.rangeOfCharacter(from:.controlCharacters) == nil,
              expected.first(where:{ $0.path == "." })?.kind == "directory",
              expected.allSatisfy({ $0.owner == UInt32(getuid()) || $0.owner == 0 }) else {
            throw ShouError("permission_denied", "Only a fully observed local application owned by the current user or the system may use native application recycling.")
        }
        _ = try applicationParentIdentity(URL(fileURLWithPath:path).deletingLastPathComponent().path)
        if applicationRecycler == nil, getuid() != 0, supportsSystemAuthorization,
           expected.contains(where: { $0.owner == 0 }) || applicationNeedsAuthorization(path) {
            // Create the caller's native Trash as that caller before elevating.
            _ = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let reply=try NativeSystemAuthorization.shared.perform(.trashApplication, path: path, manifest: expected)
            guard let destination=reply.path, let snapshot=reply.snapshot else { throw AuthorizationChannel.failure() }
            return TrashResult(path: destination, manifest: snapshot.entries, verified: snapshot.complete &&
                FileManifestVerification.matches(snapshot.entries, expected, allowingTrashRootChanges: true))
        }
        return try moveToTrashChecked(path,expected:expected,applicationRecycler:applicationRecycler ?? SystemApplicationRecycler())
        #else
        throw ShouError("capability_unavailable", "Authorized application recycling is available only on macOS.")
        #endif
    }
    private func moveToTrashChecked(_ path: String, expected: [FileEntry], applicationRecycler: (any ApplicationRecycling)?) throws -> TrashResult {
        #if os(macOS)
        guard let original=expected.first(where: { $0.path == "." }),
              original.kind == "directory" || (original.kind == "file" && expected.count == 1 && original.contentDigest != nil) else {
            throw ShouError("invalid_argument", "A complete file or directory manifest is required before moving to Trash.")
        }
        let (parentFD, name)=try SecurePaths.parent(path, cancelled: { false }); defer { close(parentFD) }
        let targetFD=openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (original.kind == "directory" ? O_DIRECTORY : 0))
        guard targetFD >= 0 else { throw SecurePaths.failure("Open Trash target without following links", path: path) }
        defer { close(targetFD) }
        var parent=stat(), pinned=stat()
        guard fstat(parentFD, &parent) == 0, fstat(targetFD, &pinned) == 0,
              SecurePaths.entry(pinned, path: ".") == original.metadata else {
            throw ShouError("plan_stale", "The Trash target changed before verification.")
        }
        try verify(path, expected)
        let (currentParentFD, currentName)=try SecurePaths.parent(path, cancelled: { false }); defer { close(currentParentFD) }
        var currentParent=stat(), currentTarget=stat()
        guard currentName == name, fstat(currentParentFD, &currentParent) == 0,
              SecurePaths.entry(parent, path: ".").sameObject(as: SecurePaths.entry(currentParent, path: ".")),
              fstatat(parentFD, name, &currentTarget, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(currentTarget, path: ".") == original.metadata else {
            throw ShouError("plan_stale", "The Trash target or its parent changed before the system operation.")
        }
        let destinationPath: String
        do {
            if let applicationRecycler { destinationPath=try NativeApplicationTrash.recycle(path,recycler:applicationRecycler) }
            else {
                var destination: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &destination)
                guard let destination, destination.isFileURL, let value=destination.path else {
                    throw ShouError("trash_outcome_unknown", "Trash operation did not report its destination. Inspect the system Trash before retrying.")
                }
                destinationPath=value
            }
        }
        catch {
            // An API failure alone cannot prove the original is still in place.
            do { try verify(path, expected) }
            catch { throw ShouError("trash_outcome_unknown", "Trash operation could not be reconciled. Verify the recorded locations before taking another action.") }
            throw error
        }
        let tree = try? inspectMutationTarget(destinationPath, entryCount: expected.count)
        let moved = tree?.entries.first { $0.path == "." }
        let trustedDestination=applicationRecycler?.isTrashLocation(destinationPath) ?? isTrashLocation(destinationPath)
        var verified = tree?.complete == true && moved.map { original.sameObject(as: $0) } == true && trustedDestination
        if original.kind == "file" { verified = verified && moved?.matchesTrashRoot(as: original) == true }
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
        #if os(macOS)
        if getuid() != 0, supportsSystemAuthorization, destination.lowercased().hasSuffix(".app"),
           expected.contains(where: { $0.owner == 0 }) || applicationNeedsAuthorization(destination) {
            try NativeSystemAuthorizationWorker.validateApplicationPath(destination, roots: applicationRoots, requireExisting: false, verifyFilesystem: false)
            _ = try NativeSystemAuthorization.shared.perform(.restoreApplication, path: destination, manifest: expected, trashPath: path)
            return
        }
        if getuid() != 0, supportsSystemAuthorization, applicationNeedsAuthorization(destination) {
            _ = try NativeSystemAuthorization.shared.perform(.restorePath,path:destination,manifest:expected,trashPath:path,
                fullDiskAccess:[.available,.notRequired].contains(scanPrivacyPolicy.status))
            return
        }
        #endif
        try verify(path, expected, trashReceipt: true)
        let (sourceFD, sourceName) = try SecurePaths.parent(path, cancelled: { false }); defer { close(sourceFD) }
        let (destinationFD, destinationName) = try SecurePaths.parent(destination, cancelled: { false }); defer { close(destinationFD) }
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
        try purge(path, expected: expected, progress: { _, _, _ in })
    }
    public func purge(_ path: String, expected: [FileEntry], progress: (Int, Int, String) -> Void) throws {
        var context=PermanentRemovalContext()
        try purge(path, expected: expected, context: &context, progress: progress)
    }
    public func purge(_ path: String, expected: [FileEntry], context: inout PermanentRemovalContext, progress: (Int, Int, String) -> Void) throws {
        try purge(path, expected: expected, context: &context, progress: progress, checking: { _ in })
    }
    public func purge(_ path: String, expected: [FileEntry], context: inout PermanentRemovalContext, progress: (Int, Int, String) -> Void, checking: @Sendable (ScanProgress) -> Void) throws {
        #if os(macOS)
        if expected.count == 1, expected.first?.kind == "symlink" {
            if getuid() != 0, supportsSystemAuthorization, removalNeedsAuthorization(path, expected: expected) {
                _ = try NativeSystemAuthorization.shared.perform(.purgeApplicationShortcut, path: path, manifest: expected)
            } else {
                try NativeApplicationShortcut.remove(path, expected: expected, roots: applicationRoots, uid: getuid())
            }
            progress(1, 1, path)
            return
        }
        if getuid() != 0, supportsSystemAuthorization,
           path.lowercased().hasSuffix(".app"), expected.first?.kind == "directory",
           removalNeedsAuthorization(path, expected: expected) {
            let operation: AuthorizationOperation
            if isTrashLocation(path) {
                try NativeAuthorizedTrash.validate(path, home: FileManager.default.homeDirectoryForCurrentUser.path, uid: getuid())
                operation = .purgeTrashedApplication
            } else {
                try NativeSystemAuthorizationWorker.validateApplicationPath(path, roots: applicationRoots, verifyFilesystem: false)
                operation = .purgeApplication
            }
            _ = try NativeSystemAuthorization.shared.perform(operation, path: path, manifest: context.reconciled(expected), progress: { reply in
                if let completed=reply.completed, let total=reply.total { progress(completed, total, reply.path ?? path) }
            })
            return
        }
        if getuid() != 0, supportsSystemAuthorization, removalNeedsAuthorization(path, expected: expected) {
            let manifest=context.reconciled(expected)
            try NativeAuthorizedFileSystem.validateReadPath(path, home: FileManager.default.homeDirectoryForCurrentUser.path)
            _ = try NativeSystemAuthorization.shared.perform(isTrashLocation(path) ? .purgeTrashPath : .purgePath, path: path, manifest: manifest,
                fullDiskAccess: [.available, .notRequired].contains(scanPrivacyPolicy.status), progress: { reply in
                    if let completed=reply.completed, let total=reply.total { progress(completed, total, reply.path ?? path) }
                })
            return
        }
        #endif
        var processed=0, lastReport=ProcessInfo.processInfo.systemUptime
        func report(_ current: String) {
            processed += 1
            let time=ProcessInfo.processInfo.systemUptime
            if processed == 1 || processed == expected.count || time - lastReport >= 0.1 {
                progress(processed, expected.count, current); lastReport=time
            }
        }
        let reconciled=context.reconciled(expected)
        if reconciled.count == 1, let file=reconciled.first, file.kind == "file", file.contentDigest != nil {
            try verify(path, reconciled, trashReceipt: true, cancelled: { Task.isCancelled }, progress: checking)
            let (fd, name)=try SecurePaths.parent(path); defer { close(fd) }
            var current=stat()
            guard fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecurePaths.failure("Inspect selected file", path: path) }
            var observed=SecurePaths.entry(current, path: ".")
            observed.contentDigest=file.contentDigest
            guard observed == file || observed.matchesTrashRoot(as: file) else { throw ShouError("plan_stale", "Selected file changed before removal.") }
            try unlinkFile(parent: fd, name: name, path: path, expected: observed.metadata, context: &context)
            report(path)
            return
        }
        guard expected.first(where: { $0.path == "." })?.kind == "directory" else {
            throw ShouError("capability_unavailable", "Permanent removal of file targets is unavailable.")
        }
        try verify(path, reconciled, trashReceipt: true, cancelled: { Task.isCancelled }, progress: checking)
        let directories=try PermanentRemovalDirectories(path: path, manifest: reconciled)
        var failures=[String](), failureCount=0, removed=0
        func attempt(_ full: String, _ mutation: () throws -> Void) throws {
            do { try mutation(); removed += 1 }
            catch let error as ShouError where ["permission_denied", "io_error"].contains(error.code) {
                failureCount += 1
                if failures.count < 10 { failures.append(full + ": " + error.message) }
            }
            report(full)
        }
        // Only known manifest entries are removed. New entries cause rmdir to fail.
        // Verification above compared this manifest with a lexically ordered
        // tree. Its reverse is postorder without another sort.
        for entry in expected.reversed() where entry.path != "." {
            if Task.isCancelled { throw ShouError("cancelled", "Permanent removal cancelled; inspect the partial result.") }
            let full = path + "/" + entry.path
            try attempt(full) {
                let (fd, name) = try directories.parent(of: entry)
                let saved=context.reconciled(entry)
                if entry.kind == "file", saved.links == 1 {
                    // unlinkFile performs the complete comparison immediately before unlinkat.
                    try unlinkFile(parent: fd, name: name, path: full, expected: saved, context: &context)
                    return
                }
                var info=stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecurePaths.failure("Inspect receipt entry", path: full) }
                let current = SecurePaths.entry(info, path: entry.path)
                guard current.sameObject(as: saved), entry.kind == "directory" || current == saved else { throw ShouError("plan_stale", "Receipt entry changed; permanent removal stopped.") }
                if entry.kind == "file" {
                    try unlinkFile(parent: fd, name: name, path: full, expected: saved, context: &context)
                } else {
                    guard unlinkat(fd, name, entry.kind == "directory" ? AT_REMOVEDIR : 0) == 0 else { throw SecurePaths.failure("Remove receipt entry", path: full) }
                }
            }
        }
        guard let original=expected.first(where: { $0.path == "." }) else { throw ShouError("plan_stale", "Receipt root changed.") }
        let (fd, name) = try directories.parent(of: original)
        var info=stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(info, path: ".").sameObject(as: original) else { throw ShouError("plan_stale", "Receipt root changed.") }
        try attempt(path) {
            guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw SecurePaths.failure("Remove receipt target", path: path) }
        }
        if !failures.isEmpty {
            throw ShouError("partial_removal", "Some files could not be permanently removed. Other eligible files were processed.",
                details: ["removed_entries": String(removed), "failed_entries": String(failureCount), "failures": failures.joined(separator: "\n")])
        }
    }

    private func unlinkFile(parent: Int32, name: String, path: String, expected: FileEntry, context: inout PermanentRemovalContext) throws {
        // Pin only shared inodes. Most cache files retain the ordinary unlink path.
        let descriptor=expected.links > 1 ? openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) : -1
        defer { if descriptor >= 0 { close(descriptor) } }
        var metadata=stat()
        if expected.links > 1 {
            guard descriptor >= 0 else { throw SecurePaths.failure("Pin hard-linked file", path: path) }
            guard fstat(descriptor, &metadata) == 0, SecurePaths.entry(metadata, path: expected.path) == expected else {
                throw ShouError("plan_stale", "The hard-linked file changed before permanent removal.")
            }
        }
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == EACCES || errno == EPERM { throw SecurePaths.failure("Inspect receipt file", path: path) }
            throw ShouError("plan_stale", "The file changed before permanent removal.")
        }
        guard SecurePaths.entry(metadata, path: expected.path) == expected else {
            throw ShouError("plan_stale", "The file changed before permanent removal.")
        }
        guard unlinkat(parent, name, 0) == 0 else { throw SecurePaths.failure("Remove receipt file", path: path) }
        if descriptor >= 0 {
            guard fstat(descriptor, &metadata) == 0 else { throw ShouError("purge_outcome_unknown", "The file was unlinked but its remaining hard links could not be verified.", details: ["path": path]) }
            try context.recordUnlink(before: expected, after: SecurePaths.entry(metadata, path: expected.path))
        }
    }
}
#endif
