import Foundation
import ShouCore
#if os(macOS)
import Darwin

/// Filesystem privilege is shared by cleanup, space analysis and large files.
/// Read scope is independent of mutation scope; business eligibility stays in Core.
enum NativeAuthorizedFileSystem {
    static func validateReadPath(_ path: String, home: String) throws {
        let parts=try SecurePaths.components(path)
        guard path == "/" + parts.joined(separator: "/"), path.rangeOfCharacter(from: .controlCharacters) == nil,
              !["/dev", "/proc", "/sys", "/private/var/run"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw ShouError("permission_denied", "This path is outside local filesystem access.")
        }
        let normalized=path.lowercased(), callerHome=home.lowercased()
        let physical=normalized.hasPrefix("/system/volumes/data/") ? String(normalized.dropFirst("/system/volumes/data".count)) : normalized
        if physical.hasPrefix("/users/"), physical != callerHome, !physical.hasPrefix(callerHome + "/"), physical != "/users/shared", !physical.hasPrefix("/users/shared/") {
            throw ShouError("protected_content", "Other users' private directories are outside this session.")
        }
    }

    static func validateMutation(_ path: String, manifest: [FileEntry], home: String, uid: UInt32, requireExisting: Bool = true, allowHardLinks: Bool = false, privateTrash: Bool = false) throws {
        try validateReadPath(path, home: home)
        let compared=path.lowercased(), comparedHome=home.lowercased()
        let blocked=["/", home, "/Users", "/System", "/Library", "/Applications", "/Volumes", "/private", "/usr", "/bin", "/sbin", "/etc", "/dev"]
        let data=URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Shou").path
        let sensitive=[".ssh", ".gnupg", ".aws", ".kube", "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage"].map { home + "/" + $0 }
        guard !blocked.map({ $0.lowercased() }).contains(compared), compared != comparedHome + "/.trash", !["/System/", "/Library/", "/Applications/", "/usr/", "/bin/", "/sbin/", "/etc/", "/dev/", "/private/etc/", "/private/var/db/", data + "/"].contains(where: { compared.hasPrefix($0.lowercased()) }),
              (privateTrash || !compared.hasPrefix(comparedHome + "/.trash/")),
              !sensitive.contains(where: { let protected=$0.lowercased(); return compared == protected || compared.hasPrefix(protected + "/") || protected.hasPrefix(compared + "/") }),
              path != data, !manifest.isEmpty, manifest.count <= 1_000_000,
              manifest.first?.path == ".", ["directory", "file"].contains(manifest.first?.kind ?? ""),
              Set(manifest.map(\.path)).count == manifest.count,
              manifest.allSatisfy({ entry in
                  entry.owner == uid && ["directory", "file", "symlink"].contains(entry.kind) &&
                  (allowHardLinks || entry.kind != "file" || entry.links == 1) &&
                  (entry.path == "." || (StorageRemovalPolicy.validRelative(entry.path) && !entry.path.contains("\\")))
              }) else { throw ShouError("protected_content", "Administrator access does not permit changing protected or foreign-owned content.") }
        if !requireExisting { return }
        let (parent, name)=try SecurePaths.parent(path)
        defer { close(parent) }
        var metadata=stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(metadata, path: ".") == manifest[0].metadata else {
            throw ShouError("plan_stale", "The selected item changed before authorized removal.")
        }
    }

    static func perform(_ request: AuthorizationRequest, descriptor: Int32, home: String, uid: UInt32) throws -> AuthorizationReply {
        guard request.action == nil, request.trashPath == nil || request.operation == .restorePath else { throw AuthorizationChannel.failure() }
        try validateReadPath(request.path, home: home)
        let excluded=otherHomes(home: home, uid: uid)
        let privacy=ScanPrivacyPolicy(status: request.fullDiskAccess == true ? .available : .limited, home: home, excludedRoots: excluded)
        let filesystem=NativeFileSystem(scanPrivacyPolicy: privacy)
        @Sendable func scanProgress(_ update: ScanProgress) {
            try? AuthorizationChannel.write(AuthorizationReply(id: request.id, progress: true, scanProgress: update), to: descriptor)
        }
        if request.operation == .pathIdentity {
            guard request.manifest == nil, request.rules == nil, request.budget == nil else { throw AuthorizationChannel.failure() }
            if request.path == "/" { return AuthorizationReply(id: request.id, identity: try filesystem.analysisRootIdentity(request.path)) }
            let (parent, name)=try SecurePaths.parent(request.path)
            defer { close(parent) }
            var metadata=stat()
            guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return AuthorizationReply(id: request.id) }
                throw SecurePaths.failure("Inspect authorized path", path: request.path)
            }
            return AuthorizationReply(id: request.id, identity: SecurePaths.entry(metadata, path: "."))
        }
        guard (try URL(fileURLWithPath: request.path).resourceValues(forKeys: [.volumeIsLocalKey])).volumeIsLocal == true else {
            throw ShouError("capability_unavailable", "Authorized filesystem access requires a local volume.")
        }
        if [.purgePath, .trashPath, .restorePath, .purgeTrashPath].contains(request.operation) {
            guard let manifest=request.manifest, request.budget == nil, request.rules == nil else { throw AuthorizationChannel.failure() }
            if request.operation == .purgeTrashPath {
                try NativeAuthorizedTrash.validate(request.path,home:home,uid:uid,applicationOnly:false)
                try validateMutation(request.path,manifest:manifest,home:home,uid:uid,privateTrash:true)
            } else {
                try privacy.checkRoot(request.path)
                try validateMutation(request.path, manifest: manifest, home: home, uid: uid, requireExisting: request.operation != .restorePath,
                    allowHardLinks: request.operation == .trashPath || request.operation == .restorePath)
            }
            let mutationFilesystem=NativeFileSystem(scanPrivacyPolicy:ScanPrivacyPolicy(status:.notRequired,home:home))
            if request.operation == .trashPath {
                let (path, snapshot)=try NativeAuthorizedTrash.move(request.path,manifest:manifest,home:home,uid:uid,filesystem:mutationFilesystem,applicationOnly:false)
                return AuthorizationReply(id:request.id,snapshot:snapshot,path:path)
            }
            if request.operation == .restorePath {
                guard let source=request.trashPath else { throw AuthorizationChannel.failure() }
                try NativeAuthorizedTrash.validate(source,home:home,uid:uid,applicationOnly:false)
                try mutationFilesystem.restore(source,to:request.path,expected:manifest)
                return AuthorizationReply(id:request.id)
            }
            try mutationFilesystem.purge(request.path, expected: manifest, progress: { completed, total, path in
                try? AuthorizationChannel.write(AuthorizationReply(id: request.id, progress: true, completed: completed, total: total, path: path), to: descriptor)
            })
            return AuthorizationReply(id: request.id)
        }
        guard request.manifest == nil else { throw AuthorizationChannel.failure() }
        if request.operation == .measureStoragePath {
            guard request.budget == nil, request.rules == nil else { throw AuthorizationChannel.failure() }
            let (path, measurement)=try exportStorage(request.path, filesystem: filesystem, uid: uid, progress: scanProgress)
            return AuthorizationReply(id: request.id, storage: measurement, path: path)
        }
        guard let budget=request.budget else { throw AuthorizationChannel.failure() }
        try budget.validate()
        let snapshot: TreeSnapshot
        if request.operation == .inspectCleanupPath {
            guard let rules=request.rules, rules.count <= 10_000 else { throw AuthorizationChannel.failure() }
            snapshot=try filesystem.inspectCleanup(request.path, rules: rules, budget: budget, cancelled: { Task.isCancelled }, progress: scanProgress)
        } else {
            guard request.operation == .inspectPath, request.rules == nil else { throw AuthorizationChannel.failure() }
            snapshot=try filesystem.inspectStorageTarget(request.path, budget: budget, cancelled: { Task.isCancelled }, progress: scanProgress)
        }
        return AuthorizationReply(id: request.id, snapshot: snapshot)
    }

    private static func otherHomes(home: String, uid: UInt32) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? []).compactMap { name in
            let path="/Users/" + name
            var metadata=stat()
            return path != home && name != "Shared" && lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR && metadata.st_uid != uid ? path : nil
        }
    }

    /// Root writes SQLite only in a new root-private temporary directory. It
    /// transfers ownership after closing the database; no caller output path is opened as root.
    static func exportStorage(_ path: String, filesystem: NativeFileSystem, uid: UInt32,
                              progress: @escaping @Sendable (ScanProgress) -> Void) throws -> (String, StorageMeasurement) {
        var template=Array("/private/tmp/shou-storage-XXXXXXXX".utf8CString)
        // mkdtemp returns a pointer into the supplied buffer. Copy its path
        // before that buffer's pointer scope ends, including optimized builds.
        let created=template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let made=mkdtemp(buffer.baseAddress!) else { return nil }
            return String(cString: made)
        }
        guard let directory=created else { throw SecurePaths.failure("Create analysis transfer", path: "/private/tmp") }
        let catalog=directory + "/catalog.sqlite"
        var published=false
        defer { if !published { try? FileManager.default.removeItem(atPath: directory) } }
        let measured=try filesystem.measureStorageDirect(path, catalog: URL(fileURLWithPath: catalog), cancelled: { Task.isCancelled }, progress: progress)
        guard chmod(catalog, 0o600) == 0, chown(catalog, uid, gid_t.max) == 0,
              chown(directory, uid, gid_t.max) == 0 else { throw SecurePaths.failure("Publish analysis transfer", path: catalog) }
        published=true
        return (catalog, measured)
    }

    static func importStorage(_ source: String, to destination: URL, uid: UInt32) throws {
        let directory=URL(fileURLWithPath: source).deletingLastPathComponent().path
        guard source == directory + "/catalog.sqlite", URL(fileURLWithPath: directory).deletingLastPathComponent().path == "/private/tmp",
              URL(fileURLWithPath: directory).lastPathComponent.hasPrefix("shou-storage-") else { throw AuthorizationChannel.failure() }
        let parent=try SecurePaths.directory(directory)
        defer { close(parent) }
        var metadata=stat()
        guard fstat(parent, &metadata) == 0, metadata.st_uid == uid, metadata.st_mode & 0o077 == 0 else { throw AuthorizationChannel.failure() }
        // Only this generated, private transfer is disposable, including when
        // import fails. Never leave a published database after a failed copy.
        defer { unlinkat(parent, "catalog.sqlite", 0); rmdir(directory) }
        let input=openat(parent, "catalog.sqlite", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw AuthorizationChannel.failure() }
        defer { close(input) }
        var before=stat()
        guard fstat(input, &before) == 0, before.st_uid == uid, before.st_nlink == 1,
              before.st_mode & S_IFMT == S_IFREG, before.st_size <= 4_294_967_296 else { throw AuthorizationChannel.failure() }
        let (outputParent, name)=try SecurePaths.parent(destination.path)
        defer { close(outputParent) }
        let output=openat(outputParent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw SecurePaths.failure("Create analysis index", path: destination.path) }
        defer { close(output) }
        var buffer=[UInt8](repeating: 0, count: 1_048_576), copied: Int64=0, complete=false
        defer { if !complete { unlinkat(outputParent, name, 0) } }
        while true {
            let count=buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw AuthorizationChannel.failure() }
            if count == 0 { break }
            copied += Int64(count)
            guard copied <= before.st_size else { throw AuthorizationChannel.failure() }
            try buffer.withUnsafeBytes { bytes in
                var written=0
                while written < count {
                    let size=Darwin.write(output, bytes.baseAddress!.advanced(by: written), count - written)
                    if size < 0 && errno == EINTR { continue }
                    guard size > 0 else { throw SecurePaths.failure("Write analysis index", path: destination.path) }
                    written += size
                }
            }
        }
        var after=stat()
        guard copied == before.st_size, fstat(input, &after) == 0,
              SecurePaths.entry(before, path: ".") == SecurePaths.entry(after, path: "."), fsync(output) == 0 else { throw AuthorizationChannel.failure() }
        complete=true
    }

    static func discardStorage(_ source: String, uid: UInt32) {
        let directory=URL(fileURLWithPath:source).deletingLastPathComponent().path
        guard source == directory + "/catalog.sqlite", URL(fileURLWithPath:directory).deletingLastPathComponent().path == "/private/tmp",
              URL(fileURLWithPath:directory).lastPathComponent.hasPrefix("shou-storage-"), let parent=try? SecurePaths.directory(directory) else { return }
        defer { close(parent) }
        var metadata=stat()
        guard fstat(parent,&metadata) == 0, metadata.st_uid == uid, metadata.st_mode & 0o077 == 0 else { return }
        unlinkat(parent,"catalog.sqlite",0); rmdir(directory)
    }
}

extension NativeFileSystem {
    func authorizedInspection(_ path: String, operation: AuthorizationOperation, budget: ScanBudget,
                              rules: [CleanupRule]? = nil, cancelled: () -> Bool,
                              progress: (ScanProgress) -> Void) throws -> TreeSnapshot? {
        guard usesSystemAuthorization else { return nil }
        if cancelled() { throw ShouError("cancelled", "Scan cancelled.") }
        try scanPrivacyPolicy.checkRoot(path)
        let reply=try NativeSystemAuthorization.shared.perform(operation, path: path, budget: budget, rules: rules,
            fullDiskAccess: [.available, .notRequired].contains(scanPrivacyPolicy.status), cancelled: cancelled, progress: { reply in
                if let update=reply.scanProgress { progress(update) }
            })
        if cancelled() { throw ShouError("cancelled", "Scan cancelled.") }
        guard let snapshot=reply.snapshot else { throw AuthorizationChannel.failure() }
        return snapshot
    }
    func authorizedAvailability(_ path: String, directoryOnly: Bool) -> LocationAvailability? {
        guard usesSystemAuthorization else { return nil }
        do {
            let reply=try NativeSystemAuthorization.shared.perform(.pathIdentity,path:path)
            guard let identity=reply.identity else { return .missing }
            return (directoryOnly ? identity.kind == "directory" : ["directory", "file"].contains(identity.kind)) ? .available : .unavailable("The target is a link or an unsupported file type.")
        } catch { return .unavailable(error.localizedDescription) }
    }
}
#endif
