import Foundation

/// Complete evidence comparison is shared by policy checks and native adapters.
/// An adapter may own the final comparison only when every mutation enforces it.
public enum FileManifestVerification {
    public static func matches(_ observed: [FileEntry], _ expected: [FileEntry], allowingTrashRootChanges: Bool = false) -> Bool {
        observed.count == expected.count && zip(observed, expected).allSatisfy {
            $0 == $1 || (allowingTrashRootChanges && $0.matchesTrashRoot(as: $1))
        }
    }

    static func beforeMutation(filesystem: any PlatformFileSystem, path: String, manifest: [FileEntry], budget: ScanBudget) throws {
        if filesystem.verifiesMutationManifest { return }
        let tree=try filesystem.inspectStorageTarget(path, budget: budget, cancelled: { Task.isCancelled })
        guard tree.complete, matches(tree.entries, manifest) else {
            throw ShouError("plan_stale", "Selected item changed since confirmation.")
        }
    }
}
