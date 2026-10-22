import Foundation
import ShouCore
#if os(macOS)
import Darwin
@preconcurrency import CoreServices
#endif

public struct StartupLoginRegistration: Sendable, Equatable, Hashable {
    public let id: UInt32
    public let path: String
    public let name: String
    public init(id: UInt32, path: String, name: String) { self.id=id; self.path=path; self.name=name }
}
public struct StartupLoginSnapshot: Sendable {
    public let items: [StartupLoginRegistration]
    public let complete: Bool
    public let entryCount: Int
    public init(items: [StartupLoginRegistration], complete: Bool = true, entryCount: Int? = nil) {
        self.items=items; self.complete=complete; self.entryCount=entryCount ?? items.count
    }
}
public protocol StartupLoginItemManaging: Sendable {
    func snapshot(limit: Int, deadline: ContinuousClock.Instant) throws -> StartupLoginSnapshot
    func insert(path: String) throws
    func remove(id: UInt32, path: String) throws
}

#if os(macOS)
struct NativeStartupLoginItems: StartupLoginItemManaging {
    private func list() throws -> LSSharedFileList {
        guard let list=LSSharedFileListCreate(nil,kLSSharedFileListSessionLoginItems.takeUnretainedValue(),nil)?.takeRetainedValue() else {
            throw ShouError("capability_unavailable", "Native login-item list is unavailable.")
        }
        return list
    }
    func snapshot(limit: Int, deadline: ContinuousClock.Instant) throws -> StartupLoginSnapshot {
        try check(deadline)
        let list=try list()
        guard let snapshot=LSSharedFileListCopySnapshot(list,nil)?.takeRetainedValue() else {
            throw ShouError("capability_unavailable", "Native login-item snapshot is unavailable.")
        }
        let total=CFArrayGetCount(snapshot), scanned=min(total,max(0,limit))
        var incomplete=scanned != total, items: [StartupLoginRegistration]=[], visited=0
        for index in 0..<scanned {
            if Task.isCancelled { throw ShouError("cancelled", "Startup scan stopped.") }
            if ContinuousClock.now >= deadline { incomplete=true; break }
            visited += 1
            let item=unsafeBitCast(CFArrayGetValueAtIndex(snapshot,index)!,to:LSSharedFileListItem.self)
            let flags=UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
            guard let resolved=LSSharedFileListItemCopyResolvedURL(item,flags,nil)?.takeRetainedValue() else { incomplete=true; continue }
            let url=resolved as URL
            guard url.isFileURL, url.path.hasPrefix("/"), url.path.utf8.count <= 4_096,
                  url.path.rangeOfCharacter(from:.controlCharacters) == nil else { incomplete=true; continue }
            let rawName=LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String
            let name=rawName.isEmpty || rawName.utf8.count > 512 || rawName.rangeOfCharacter(from:.controlCharacters) != nil ? url.deletingPathExtension().lastPathComponent : rawName
            items.append(StartupLoginRegistration(id:LSSharedFileListItemGetID(item),path:url.path,name:name))
        }
        return StartupLoginSnapshot(items:items,complete:!incomplete,entryCount:visited)
    }
    func insert(path: String) throws {
        let list=try list()
        guard LSSharedFileListInsertItemURL(list,kLSSharedFileListItemLast.takeUnretainedValue(),nil,nil,URL(fileURLWithPath:path) as CFURL,nil,nil) != nil else {
            throw ShouError("startup_control_failed", "The native login item could not be inserted.")
        }
    }
    func remove(id: UInt32, path: String) throws {
        let list=try list()
        guard let snapshot=LSSharedFileListCopySnapshot(list,nil)?.takeRetainedValue() else { throw ShouError("capability_unavailable", "Native login-item snapshot is unavailable.") }
        let count=CFArrayGetCount(snapshot)
        guard count <= 10_000 else { throw ShouError("resource_limit", "Login-item mutation snapshot exceeds its limit.") }
        var matches: [LSSharedFileListItem]=[]
        for index in 0..<count {
            let item=unsafeBitCast(CFArrayGetValueAtIndex(snapshot,index)!,to:LSSharedFileListItem.self)
            if LSSharedFileListItemGetID(item) == id { matches.append(item) }
        }
        guard matches.count == 1 else { throw ShouError("plan_stale", "The exact native login item no longer exists.") }
        let flags=UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        guard let resolved=LSSharedFileListItemCopyResolvedURL(matches[0],flags,nil)?.takeRetainedValue(), (resolved as URL).path == path else {
            throw ShouError("plan_stale", "The native login-item target changed before removal.")
        }
        guard LSSharedFileListItemRemove(list,matches[0]) == 0 else { throw ShouError("startup_control_failed", "The native login item could not be removed.") }
    }
    private func check(_ deadline: ContinuousClock.Instant) throws {
        if Task.isCancelled { throw ShouError("cancelled", "Startup scan stopped.") }
        guard ContinuousClock.now < deadline else { throw ShouError("resource_limit", "Login item snapshot deadline reached.") }
    }
}

enum NativeStartupLoginControl {
    /// Only an existing local third-party app with a readable ordinary Info.plist
    /// is eligible. Symlinks, Apple bundles, remote paths and offline media fail closed.
    static func bundleIdentifier(path: String, deadline: ContinuousClock.Instant) -> String? {
        guard path.lowercased().hasSuffix(".app"), NativeStartupMetadata.targetState(path) == "exists",
              !["/System", "/usr", "/bin", "/sbin", "/Library/Apple"].contains(where:{ path == $0 || path.hasPrefix($0 + "/") }) else { return nil }
        var metadata=stat()
        guard lstat(path,&metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return nil }
        let info=path + "/Contents/Info.plist"
        guard let (parent,name)=try? SecurePaths.parent(info) else { return nil }
        defer { close(parent) }
        guard let bytes=try? NativeDefinitionFiles.bytes(directory:parent,name:name,path:info,deadline:deadline),
              let values=try? PropertyListSerialization.propertyList(from:bytes,options:[],format:nil) as? [String:Any],
              let bundle=values["CFBundleIdentifier"] as? String, !bundle.hasPrefix("com.apple."),
              bundle.range(of:"^[A-Za-z0-9._-]{1,255}$",options:.regularExpression) != nil else { return nil }
        return bundle
    }
    static func manageable(path: String, bundleIdentifier expected: String? = nil, snapshot: StartupLoginSnapshot?, deadline: ContinuousClock.Instant) -> Bool {
        guard let snapshot, snapshot.complete, let bundle=bundleIdentifier(path:path,deadline:deadline),
              expected == nil || expected == bundle else { return false }
        let matches=snapshot.items.filter { $0.path == path }
        return matches.count <= 1 && Set(snapshot.items.map(\.id)).count == snapshot.items.count
    }
    static func apply(definition: StartupDefinition, action: StartupControlAction, manager: any StartupLoginItemManaging,
                      backgroundRecords: () throws -> [StartupBackgroundRecord]) throws -> StartupControlResult {
        guard action != .remove, definition.controlCapability == "login_item",
              ["macos.login_items","macos.background_tasks"].contains(definition.sourceId),
              let path=definition.applicationPath, definition.programPath == path else {
            throw ShouError("capability_unavailable", "This login registration cannot be changed directly.")
        }
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        let snapshot=try manager.snapshot(limit:10_000,deadline:deadline)
        guard manageable(path:path,snapshot:snapshot,deadline:deadline) else { throw ShouError("permission_denied", "Only an exact local third-party application registration can be managed.") }
        let matches=snapshot.items.filter { $0.path == path }
        let current=matches.isEmpty ? "disabled" : "enabled"
        guard definition.configuredState == current, current != (action == .enable ? "enabled" : "disabled") else {
            throw ShouError("plan_stale", "The native login registration state changed; scan again.")
        }
        if definition.sourceId == "macos.background_tasks" {
            let records=try backgroundRecords().filter { "btm:" + $0.identifier == definition.path }
            guard records.count == 1, let record=records.first, record.path == path, record.bundleIdentifier == definition.label,
                  manageable(path:path,bundleIdentifier:record.bundleIdentifier,snapshot:snapshot,deadline:deadline) else {
                throw ShouError("plan_stale", "The exact background application record changed; scan again.")
            }
        } else {
            guard matches.count == 1, let item=matches.first, definition.path == "login-item:\(item.id)", item.name == definition.label else {
                throw ShouError("plan_stale", "The exact native login item changed; scan again.")
            }
        }
        // Recheck the complete native identity immediately before mutation.
        let latest=try manager.snapshot(limit:10_000,deadline:deadline)
        guard latest.complete, Set(latest.items) == Set(snapshot.items),
              manageable(path:path,bundleIdentifier:definition.sourceId == "macos.background_tasks" ? definition.label : nil,snapshot:latest,deadline:deadline) else {
            throw ShouError("plan_stale", "The native login-item list or target changed before mutation.")
        }
        if action == .enable { try manager.insert(path:path) }
        else if let item=matches.first { try manager.remove(id:item.id,path:path) }
        let observed=try manager.snapshot(limit:10_000,deadline:deadline)
        let remaining=observed.items.filter { $0.path == path }
        let expected=action == .enable ? "enabled" : "disabled"
        guard observed.complete, action == .enable ? remaining.count == 1 : remaining.isEmpty else {
            throw ShouError("startup_verification_failed", "Login registration may have changed, but native readback could not verify it. Scan again before retrying.")
        }
        return StartupControlResult(definitionId:definition.id,label:definition.label,action:action,configuredState:expected,runtimeState:"unknown",controlCapability:"login_item",
            message:action == .enable ? "Login application enabled." : "Login application disabled. The running application was not stopped.")
    }
}
#endif
