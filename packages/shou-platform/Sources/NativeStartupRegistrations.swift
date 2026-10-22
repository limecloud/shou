import Foundation
import ShouCore
#if os(macOS)
import Darwin

struct NativeStartupRegistrations {
    var sources: [StartupSourceCoverage]=[]
    var items: [StartupDefinition]=[]
    var issues: [StartupInventoryIssue]=[]
    var unavailable: [String]=[]
    static let backgroundLocation=StartupLocation(id:"macos.background_tasks",path:"/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v13.btm",kind:"login_record",scope:"machine")

    static func backgroundRecords(limit: Int, deadline: ContinuousClock.Instant) throws -> [StartupBackgroundRecord] {
        try check(deadline)
        let path=backgroundLocation.path
        let (parent,name)=try SecurePaths.parent(path)
        defer { close(parent) }
        let bytes=try NativeDefinitionFiles.bytes(directory:parent,name:name,path:path,maximumBytes:StartupBackgroundArchiveParser.maximumBytes,deadline:deadline)
        return try StartupBackgroundArchiveParser.parse(bytes,limit:limit,deadline:deadline)
    }
    static func read(homeDirectory: URL, limit: Int, deadline: ContinuousClock.Instant) throws -> Self {
        var result=Self()
        var nativeSnapshot: StartupLoginSnapshot?
        let loginLocation=StartupLocation(id:"macos.login_items",path:"system-settings:login-items",kind:"login_item",scope:"user")
        do {
            let snapshot=try NativeStartupLoginItems().snapshot(limit:limit,deadline:deadline)
            nativeSnapshot=snapshot
            for login in snapshot.items {
                let identity=NativeStartupMetadata.identity(program:login.path,deadline:deadline)
                let capability=NativeStartupLoginControl.manageable(path:login.path,snapshot:snapshot,deadline:deadline) ? "login_item" : "system_settings"
                result.items.append(StartupDefinition(sourceId:loginLocation.id,path:"login-item:\(login.id)",label:login.name,programPath:login.path,
                    disabledByDefinition:false,triggers:["login_item"],configuredState:"enabled",controlCapability:capability,
                    displayName:identity.name ?? login.name,applicationPath:identity.application ?? login.path,targetState:NativeStartupMetadata.targetState(login.path)))
            }
            if !snapshot.complete { result.issues.append(StartupInventoryIssue(sourceId:loginLocation.id,path:loginLocation.path,code:"unresolved_login_items")) }
            result.sources.append(StartupSourceCoverage(location:loginLocation,status:snapshot.complete ? "complete" : "partial",entryCount:snapshot.entryCount,definitionCount:result.items.count))
        } catch let error as ShouError {
            if error.code == "cancelled" { throw error }
            result.issues.append(StartupInventoryIssue(sourceId:loginLocation.id,path:loginLocation.path,code:error.code))
            result.sources.append(StartupSourceCoverage(location:loginLocation,status:"unavailable",entryCount:0,definitionCount:0))
            result.unavailable.append("login_items")
        }
        let background=backgroundLocation
        do {
            let records=try backgroundRecords(limit:max(0,limit-result.items.count),deadline:deadline)
            var found: [StartupDefinition]=[]
            let enabledPaths=nativeSnapshot.flatMap { $0.complete ? Set($0.items.map(\.path)) : nil }
            for record in records {
                try check(deadline)
                let identity=NativeStartupMetadata.identity(program:record.path,deadline:deadline)
                let enabled=enabledPaths.map { $0.contains(record.path) } ?? record.enabled
                let capability=NativeStartupLoginControl.manageable(path:record.path,bundleIdentifier:record.bundleIdentifier,snapshot:nativeSnapshot,deadline:deadline) ? "login_item" : "system_settings"
                found.append(StartupDefinition(sourceId:background.id,path:"btm:" + record.identifier,label:record.bundleIdentifier,programPath:record.path,
                    disabledByDefinition:!enabled,triggers:["login_item"],configuredState:enabled ? "enabled" : "disabled",controlCapability:capability,
                    displayName:identity.name ?? record.name,applicationPath:record.path,publisher:record.publisher,targetState:NativeStartupMetadata.targetState(record.path)))
            }
            let archivedPaths=Set(found.compactMap(\.applicationPath))
            result.items.removeAll { $0.applicationPath.map { archivedPaths.contains($0) } == true }
            result.items += found
            result.sources.append(StartupSourceCoverage(location:background,status:"complete",entryCount:records.count,definitionCount:found.count))
        } catch let error as ShouError {
            if error.code == "cancelled" { throw error }
            result.issues.append(StartupInventoryIssue(sourceId:background.id,path:background.path,code:error.code))
            result.sources.append(StartupSourceCoverage(location:background,status:"unavailable",entryCount:0,definitionCount:0))
            result.unavailable.append("background_task_registrations")
        }
        return result
    }
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        if Task.isCancelled { throw ShouError("cancelled", "Startup scan stopped.") }
        guard ContinuousClock.now < deadline else { throw ShouError("resource_limit", "Startup registration deadline reached.") }
    }
}
#endif
