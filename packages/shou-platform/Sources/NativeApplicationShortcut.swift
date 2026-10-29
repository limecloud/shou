import Foundation
import ShouCore
#if os(macOS)
import Darwin

/// Only dangling .app links below the fixed installation roots are accepted.
/// Target observation never grants permission to mutate the referenced object.
enum NativeApplicationShortcut {
    static func snapshot(_ path: String, roots: [String], uid: UInt32) throws -> ApplicationShortcutSnapshot {
        try NativeSystemAuthorizationWorker.validateApplicationPath(path, roots: roots, verifyFilesystem: false)
        let (parent, name)=try SecurePaths.parent(path)
        defer { close(parent) }
        return try snapshot(parent: parent, name: name, path: path, uid: uid)
    }

    private static func snapshot(parent: Int32, name: String, path: String, uid: UInt32) throws -> ApplicationShortcutSnapshot {
        var link=stat(), directory=stat()
        guard fstat(parent, &directory) == 0, fstatat(parent, name, &link, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SecurePaths.failure("Inspect application shortcut", path: path)
        }
        guard link.st_mode & S_IFMT == S_IFLNK, [uid, 0].contains(link.st_uid), link.st_nlink == 1 else {
            throw ShouError("protected_content", "Only a broken application shortcut owned by this user or the system can be removed.")
        }
        var target=stat()
        guard fstatat(parent, name, &target, 0) != 0, errno == ENOENT else {
            throw ShouError("plan_stale", "The shortcut target exists or could not be verified; nothing was removed.")
        }
        var bytes=[UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count=bytes.withUnsafeMutableBytes { readlinkat(parent, name, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count) }
        guard count > 0, count < bytes.count else { throw ShouError("plan_stale", "The shortcut target could not be verified.") }
        var current=stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(current, path: ".") == SecurePaths.entry(link, path: ".") else {
            throw ShouError("plan_stale", "The shortcut changed. Check this application again.")
        }
        var identity=SecurePaths.entry(link, path: ".")
        identity.contentDigest=Digest.sha256(Data(bytes.prefix(count)))
        return ApplicationShortcutSnapshot(identity: identity, parentIdentity: SecurePaths.entry(directory, path: "."), currentUser: uid,
            requiresAdministrator: link.st_uid != uid || (geteuid() == 0 ? directory.st_uid != uid : faccessat(parent, ".", W_OK | X_OK, 0) != 0))
    }

    static func remove(_ path: String, expected: [FileEntry], roots: [String], uid: UInt32) throws {
        guard expected.count == 1, expected.first?.path == ".", expected.first?.kind == "symlink", expected.first?.contentDigest != nil else {
            throw ShouError("plan_stale", "An exact broken shortcut identity is required.")
        }
        try NativeSystemAuthorizationWorker.validateApplicationPath(path, roots: roots, verifyFilesystem: false)
        let (parent, name)=try SecurePaths.parent(path)
        defer { close(parent) }
        guard try snapshot(parent: parent, name: name, path: path, uid: uid).identity == expected[0] else {
            throw ShouError("plan_stale", "The shortcut changed. Check this application again.")
        }
        if Task.isCancelled { throw ShouError("cancelled", "Shortcut cleanup cancelled.") }
        guard unlinkat(parent, name, 0) == 0 else { throw SecurePaths.failure("Remove broken application shortcut", path: path) }
    }
}
#endif
