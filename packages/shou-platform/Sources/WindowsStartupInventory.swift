import Foundation
import ShouCore
#if os(Windows)
import CShouWindows
#endif

/// Validates the bounded native source contract without inventing application
/// ownership or treating an unresolved shortcut as a missing executable.
public struct WindowsStartupInventory: StartupInventoryReading {
    public typealias Read = @Sendable (StartupInventoryOptions) throws -> Data
    private let reader: Read?
    public init(reader: Read? = nil) { self.reader=reader }

    private struct Payload: Decodable {
        let sources: [StartupSourceCoverage]
        let items: [StartupDefinition]
        let issues: [StartupInventoryIssue]
        let unavailableSources: [String]
    }
    public func read(options: StartupInventoryOptions) throws -> StartupInventory {
        try options.validate()
        if Task.isCancelled { throw ShouError("cancelled", "Startup scan stopped.") }
        let data: Data
        if let reader { data=try reader(options) }
        else {
            #if os(Windows)
            let value=try WindowsNative.string({ result in
                shou_win_startup_inventory(options.includeSystem ? 1 : 0, options.maxEntries, UInt32(max(1, options.maxSeconds * 1000)), { _ in Task.isCancelled ? 1 : 0 }, nil, result)
            }, path: "Windows startup sources")
            data=Data(value.utf8)
            #else
            throw ShouError("unsupported_platform", "Windows startup discovery requires Windows.")
            #endif
        }
        if Task.isCancelled { throw ShouError("cancelled", "Startup scan stopped.") }
        guard data.count <= 8 * 1024 * 1024 else { throw ShouError("resource_limit", "Windows startup evidence exceeds its output limit.") }
        let payload=try Codec.decode(Payload.self, from: data)
        let user: Set<String>=["windows.user_run", "windows.user_run_once", "windows.user_startup", "windows.scheduled_tasks"]
        let machine: Set<String>=["windows.machine_run64", "windows.machine_run_once64", "windows.machine_run32", "windows.machine_run_once32", "windows.machine_startup", "windows.services"]
        let expected=options.includeSystem ? user.union(machine) : user
        let counts=Dictionary(grouping: payload.items, by: \.sourceId).mapValues(\.count)
        guard Set(payload.sources.map { $0.location.id }) == expected,
              payload.sources.count == expected.count, payload.items.count <= options.maxEntries,
              Set(payload.items.map(\.id)).count == payload.items.count,
              payload.issues.count <= 128,
              payload.sources.allSatisfy({ source in
                  ["complete", "missing", "partial", "unavailable", "not_scanned"].contains(source.status) &&
                  source.entryCount >= source.definitionCount && source.entryCount <= options.maxEntries &&
                  source.definitionCount == (counts[source.location.id] ?? 0) &&
                  source.location.systemOwned == machine.contains(source.location.id)
              }),
              payload.issues.allSatisfy({ expected.contains($0.sourceId) }),
              payload.items.allSatisfy({ item in
                  expected.contains(item.sourceId) && !item.path.isEmpty && !item.label.isEmpty &&
                  ["enabled", "disabled", "unknown"].contains(item.configuredState) &&
                  ["running", "not_running", "queued", "unknown"].contains(item.runtimeState) &&
                  ["exists", "missing", "unknown"].contains(item.targetState) && !item.removable &&
                  item.applicationPath == nil && item.publisher == nil &&
                  (item.controlCapability == "system_settings" || Self.isControllableTask(item))
              }) else { throw ShouError("invalid_startup_evidence", "Windows startup source coverage or identity is inconsistent.") }
        return StartupInventory(checkedAt: Date(), includeSystem: options.includeSystem, sources: payload.sources,
            items: payload.items.sorted { ($0.label, $0.sourceId, $0.path) < ($1.label, $1.sourceId, $1.path) }, issues: payload.issues,
            scope: "windows_startup_items", unavailableSources: payload.unavailableSources)
    }

    static func isControllableTask(_ item: StartupDefinition) -> Bool {
        item.sourceId == "windows.scheduled_tasks" && item.controlCapability == "windows_user_task" &&
        item.path.hasPrefix("\\") && !item.path.contains("/") && !item.path.contains("..") &&
        !item.path.lowercased().hasPrefix("\\microsoft\\") && item.path.utf8.count <= 16_384 &&
        item.evidenceDigest?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
        !item.triggers.isEmpty && item.triggers.allSatisfy { ["login", "boot"].contains($0) }
    }
}

public struct WindowsStartupControl: StartupControlling {
    public typealias Change = @Sendable (String, String, Bool) throws -> Void
    private let change: Change?
    public init(change: Change? = nil) { self.change=change }

    public func apply(definition: StartupDefinition, action: StartupControlAction) throws -> StartupControlResult {
        guard action != .remove, WindowsStartupInventory.isControllableTask(definition),
              ["enabled", "disabled"].contains(definition.configuredState), let digest=definition.evidenceDigest else {
            throw ShouError("capability_unavailable", "Only verified current-user login or boot tasks can be toggled directly. Manage other startup sources in Windows settings.")
        }
        if Task.isCancelled { throw ShouError("cancelled", "Startup change stopped before execution.") }
        let enabled=action == .enable
        if let change { try change(definition.path, digest, enabled) }
        else {
            #if os(Windows)
            var started: Int32=0
            let status=shou_win_startup_task_control(definition.path, digest, enabled ? 1 : 0, &started)
            if status != 0 {
                if started != 0 { throw ShouError("startup_verification_failed", "Startup state may have changed, but readback could not verify the complete task definition. Scan again before retrying.") }
                throw ShouError(status == 1006 ? "plan_stale" : status == 5 ? "permission_denied" : "startup_control_failed", "Windows could not safely change this startup task. Scan again before retrying.", details: ["win32_code": String(status)])
            }
            #else
            throw ShouError("unsupported_platform", "Windows startup control requires Windows.")
            #endif
        }
        return StartupControlResult(definitionId: definition.id, label: definition.label, action: action,
            configuredState: enabled ? "enabled" : "disabled", runtimeState: "unknown", controlCapability: definition.controlCapability,
            message: "Startup task configuration was changed and read back. Running instances are not stopped.")
    }
}
