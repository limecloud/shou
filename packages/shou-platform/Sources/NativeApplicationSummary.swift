import Foundation
import ShouCore
#if os(macOS)
import CoreServices
import Darwin
#endif

extension NativeApplicationCatalog {
    /// Summary reads keep only hard-link identities and a directory traversal stack.
    /// They never retain file manifests or grant removal authority.
    public func measureSummary(for application: ApplicationDefinition, budget: ScanBudget,
                               progress: @Sendable (ScanProgress) -> Void) throws -> ApplicationSummaryMeasurement {
        #if os(macOS)
        let deadline=ContinuousClock.now.advanced(by: .seconds(budget.maxSeconds))
        let root=try SecurePaths.directory(application.path)
        defer { close(root) }
        var initial=stat()
        guard fstat(root, &initial) == 0, SecurePaths.entry(initial, path: ".").sameObject(as: application.identity) else {
            throw ShouError("application_changed", "Application changed before summary measurement.")
        }
        struct Object: Hashable { let device: UInt64; let inode: UInt64 }
        var linked=Set<Object>(), count=0, allocated: Int64=0, foreign=false, issues=Set<String>()
        func checkpoint() throws {
            if Task.isCancelled { throw ShouError("cancelled", "Application summary stopped.") }
            guard count < budget.maxEntries, ContinuousClock.now < deadline else { throw ShouError("resource_limit", "Application size measurement reached its budget.") }
        }
        func account(_ metadata: stat) throws {
            try checkpoint(); count += 1
            let kind=metadata.st_mode & S_IFMT
            if metadata.st_uid != getuid() { foreign=true }
            if kind == S_IFLNK { return }
            guard kind == S_IFDIR || kind == S_IFREG else { issues.insert("unsupported_component_type"); return }
            if kind == S_IFREG, metadata.st_nlink > 1 {
                guard linked.insert(Object(device: UInt64(metadata.st_dev), inode: metadata.st_ino)).inserted else { return }
                issues.insert("multiply_linked_content")
            }
            let (sum, overflow)=allocated.addingReportingOverflow(max(0, Int64(metadata.st_blocks)) * 512)
            guard !overflow else { throw ShouError("resource_limit", "Application allocation exceeds supported limits.") }
            allocated=sum
        }
        func walk(_ descriptor: Int32, depth: Int) throws {
            try checkpoint()
            guard depth <= budget.maxDepth else { issues.insert("depth_limit"); return }
            let listing=try NativeDefinitionFiles.names(descriptor, limit: max(0, budget.maxEntries - count), deadline: deadline)
            if listing.truncated { issues.insert("resource_limit") }
            for name in listing.names {
                try checkpoint()
                var metadata=stat()
                guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { issues.insert("unreadable_entry"); continue }
                guard metadata.st_dev == initial.st_dev else { issues.insert("cross_filesystem"); continue }
                try account(metadata)
                if metadata.st_mode & S_IFMT == S_IFDIR {
                    let child=openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { issues.insert("unreadable_directory"); continue }
                    do {
                        defer { close(child) }
                        var opened=stat()
                        guard fstat(child, &opened) == 0, opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino else {
                            issues.insert("application_changed"); continue
                        }
                        try walk(child, depth: depth + 1)
                    }
                }
                if count % 256 == 0 { progress(ScanProgress(stage: "measuring", entryCount: count, currentPath: application.path)) }
            }
        }
        do { try account(initial); try walk(root, depth: 0) }
        catch let error as ShouError { if error.code == "cancelled" { throw error }; issues.insert(error.code) }
        let (parent, name)=try SecurePaths.parent(application.path)
        defer { close(parent) }
        var final=stat()
        guard fstatat(parent, name, &final, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(initial, path: ".") == SecurePaths.entry(final, path: ".") else {
            throw ShouError("application_changed", "Application changed during size measurement.")
        }
        var lastUsed: Date?
        if let item=MDItemCreateWithURL(kCFAllocatorDefault, URL(fileURLWithPath: application.path) as CFURL) {
            lastUsed=MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        }
        progress(ScanProgress(stage: "measuring", entryCount: count, currentPath: application.path))
        return ApplicationSummaryMeasurement(allocatedBytesEstimate: allocated, owner: initial.st_uid,
            containsForeignOwnedContent: foreign, lastUsed: lastUsed, issues: issues.sorted())
        #else
        throw ShouError("unsupported_platform", "Application size measurement is currently available only on macOS.")
        #endif
    }
}
