import Foundation
import ShouCore
#if os(macOS)
import Darwin

/// The authenticated worker moves only an observed item into its caller's
/// private Trash. Staging pins the source before checking the complete manifest.
enum NativeAuthorizedTrash {
    static func validate(_ path: String, home: String, uid: UInt32, applicationOnly: Bool = true) throws {
        let directory=home + "/.Trash"
        guard URL(fileURLWithPath: path).deletingLastPathComponent().path == directory,
              path == directory + "/" + URL(fileURLWithPath: path).lastPathComponent,
              !URL(fileURLWithPath:path).lastPathComponent.hasPrefix("."),
              (!applicationOnly || path.range(of: #" Shou-[0-9A-Fa-f-]{36}\.app$"#, options: .regularExpression) != nil) else {
            throw ShouError("permission_denied", "This is not a recorded authorized item Trash location.")
        }
        let descriptor=try SecurePaths.directory(directory)
        defer { close(descriptor) }
        var metadata=stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == uid, metadata.st_mode & 0o077 == 0 else {
            throw ShouError("permission_denied", "The private Trash directory is not private to the caller.")
        }
    }

    static func move(_ path: String, manifest: [FileEntry], home: String, uid: UInt32, filesystem: NativeFileSystem, applicationOnly: Bool = true) throws -> (String, TreeSnapshot) {
        let originalURL=URL(fileURLWithPath:path), suffix=originalURL.pathExtension
        let extensionPart=applicationOnly ? ".app" : suffix.isEmpty ? "" : "." + String(suffix.prefix(20))
        let stem=String(originalURL.deletingPathExtension().lastPathComponent.drop(while: { $0 == "." }).prefix(40))
        let name=(stem.isEmpty ? "Item" : stem) + " Shou-" + UUID().uuidString + extensionPart
        let destination=home + "/.Trash/" + name
        try validate(destination, home: home, uid: uid, applicationOnly:applicationOnly)
        let (source, sourceName)=try SecurePaths.parent(path)
        defer { close(source) }
        let trash=try SecurePaths.directory(home + "/.Trash")
        defer { close(trash) }
        var original=stat(), trashInfo=stat()
        guard let root=manifest.first, fstatat(source, sourceName, &original, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(original, path: ".") == root.metadata,
              fstat(trash, &trashInfo) == 0, trashInfo.st_uid == uid, trashInfo.st_mode & 0o077 == 0,
              original.st_dev == trashInfo.st_dev else {
            throw ShouError("plan_stale", "The item or its private Trash changed; no files were moved.")
        }
        if Task.isCancelled { throw ShouError("authorization_cancelled", "The authorized move stopped before dispatch.") }
        let stagedName=".shou-staging-" + UUID().uuidString + extensionPart
        let stagedPath=URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(stagedName).path
        guard renameatx_np(source, sourceName, source, stagedName, UInt32(RENAME_EXCL)) == 0 else {
            throw SecurePaths.failure("Stage item for Trash", path: path)
        }
        do {
            let staged=try inspect(stagedPath, manifest: manifest, filesystem: filesystem)
            guard renameatx_np(source, stagedName, trash, name, UInt32(RENAME_EXCL)) == 0 else {
                throw SecurePaths.failure("Move staged item to private Trash", path: path)
            }
            do {
                let moved=try inspect(destination, manifest: staged.entries, filesystem: filesystem)
                return (destination, moved)
            } catch {
                throw ShouError("trash_outcome_unknown", "The moved item could not be verified. Inspect its recorded Trash location before retrying.", details: ["resulting_path": destination])
            }
        } catch {
            if (error as? ShouError)?.code == "trash_outcome_unknown" { throw error }
            guard renameatx_np(source, stagedName, source, sourceName, UInt32(RENAME_EXCL)) == 0 else {
                throw ShouError("trash_outcome_unknown", "The staged item could not be returned without overwriting another item.", details: ["resulting_path": stagedPath])
            }
            throw error
        }
    }

    private static func inspect(_ path: String, manifest: [FileEntry], filesystem: NativeFileSystem) throws -> TreeSnapshot {
        let tree=try filesystem.inspectStorageTarget(path, budget: ScanBudget(maxEntries: max(100_000, manifest.count + 1), maxSeconds: 180), cancelled: { false })
        guard tree.complete, FileManifestVerification.matches(tree.entries, manifest, allowingTrashRootChanges: true) else {
            throw ShouError("plan_stale", "The item contents changed before the authorized move.")
        }
        return tree
    }
}
#endif
