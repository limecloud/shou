import Foundation

/// Evidence of link-count changes caused by this execution only. Never persisted
/// or reused to authorize a later execution of a stale plan.
public struct PermanentRemovalContext {
    private var unlinks: [String: (original: FileEntry, current: FileEntry)] = [:]
    public init() {}

    public func reconciled(_ manifest: [FileEntry]) -> [FileEntry] {
        manifest.map { entry in
            guard let change=unlinks[entry.objectIdentityKey], normalized(entry) == change.original else { return entry }
            var updated=entry
            updated.links=change.current.links
            updated.changedNanoseconds=change.current.changedNanoseconds
            return updated
        }
    }

    /// The platform must pin the file, verify it before unlink, then observe the
    /// same open descriptor afterwards. Only one removed link may explain a change.
    public mutating func recordUnlink(before: FileEntry, after: FileEntry) throws {
        let before=normalized(before), after=normalized(after)
        var expected=before
        expected.links=before.links > 0 ? before.links - 1 : 0
        expected.changedNanoseconds=after.changedNanoseconds
        guard before.kind == "file", before.links > 1, expected == after,
              unlinks[before.objectIdentityKey].map({ $0.current == before }) ?? true else {
            throw ShouError("plan_stale", "The hard-linked file changed during permanent removal.")
        }
        unlinks[before.objectIdentityKey]=(unlinks[before.objectIdentityKey]?.original ?? before, after)
    }

    private func normalized(_ entry: FileEntry) -> FileEntry {
        var copy=entry.metadata; copy.path="."
        return copy
    }
}
