import Foundation
import ShouCore
#if os(macOS)
import Darwin
import CoreFoundation
#endif

public struct NativeStartupInventory: StartupInventoryReading {
    public static let maximumDefinitionBytes=262_144
    private let locations: [StartupLocation]
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, locations: [StartupLocation]? = nil) {
        self.locations=locations ?? [
            StartupLocation(id: "macos.user_agents", path: homeDirectory.appendingPathComponent("Library/LaunchAgents").path, kind: "agent", scope: "user"),
            StartupLocation(id: "macos.local_agents", path: "/Library/LaunchAgents", kind: "agent", scope: "machine"),
            StartupLocation(id: "macos.local_daemons", path: "/Library/LaunchDaemons", kind: "daemon", scope: "machine"),
            StartupLocation(id: "macos.system_agents", path: "/System/Library/LaunchAgents", kind: "agent", scope: "machine", systemOwned: true),
            StartupLocation(id: "macos.system_daemons", path: "/System/Library/LaunchDaemons", kind: "daemon", scope: "machine", systemOwned: true)
        ]
    }
    public func read(options: StartupInventoryOptions) throws -> StartupInventory {
        try options.validate()
        #if os(macOS)
        let deadline=ContinuousClock.now.advanced(by: .seconds(options.maxSeconds))
        var sources: [StartupSourceCoverage]=[], items: [StartupDefinition]=[], issues: [StartupInventoryIssue]=[]
        var visited=0
        for location in locations where options.includeSystem || !location.systemOwned {
            try checkCancellation()
            var count=0, found=0
            if ContinuousClock.now >= deadline || visited >= options.maxEntries {
                issues.append(StartupInventoryIssue(sourceId: location.id, path: location.path, code: "resource_limit"))
                sources.append(StartupSourceCoverage(location: location, status: "not_scanned", entryCount: 0, definitionCount: 0))
                continue
            }
            let issueStart=issues.count
            do {
                let (parent, name)=try SecurePaths.parent(location.path)
                defer { close(parent) }
                var metadata=stat()
                if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT {
                    sources.append(StartupSourceCoverage(location: location, status: "missing", entryCount: 0, definitionCount: 0))
                    continue
                }
                let directory=try SecurePaths.directory(location.path)
                defer { close(directory) }
                var opened=stat()
                guard fstat(directory, &opened) == 0 else { throw ShouError("io_error", "Startup directory could not be read.") }
                let listing=try NativeDefinitionFiles.names(directory, limit: options.maxEntries-visited, deadline: deadline)
                count=listing.names.count; visited += count
                if listing.truncated { issues.append(StartupInventoryIssue(sourceId: location.id, path: location.path, code: "resource_limit")) }
                for name in listing.names where name.hasSuffix(".plist") {
                    try checkCancellation()
                    if ContinuousClock.now >= deadline {
                        issues.append(StartupInventoryIssue(sourceId: location.id, path: location.path, code: "resource_limit")); break
                    }
                    let path=location.path + "/" + name
                    do {
                        let data=try NativeDefinitionFiles.bytes(directory: directory, name: name, path: path, deadline: deadline)
                        items.append(try parse(data, location: location, path: path)); found += 1
                    } catch let error as ShouError {
                        if error.code == "cancelled" { throw error }
                        issues.append(StartupInventoryIssue(sourceId: location.id, path: path, code: error.code))
                    } catch {
                        issues.append(StartupInventoryIssue(sourceId: location.id, path: path, code: "invalid_definition"))
                    }
                }
                var current=stat()
                if fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) != 0 || SecurePaths.entry(opened, path: ".") != SecurePaths.entry(current, path: ".") {
                    items.removeLast(found); found=0
                    issues.append(StartupInventoryIssue(sourceId: location.id, path: location.path, code: "definition_changed"))
                }
                sources.append(StartupSourceCoverage(location: location, status: issues.count == issueStart ? "complete" : "partial", entryCount: count, definitionCount: found))
            } catch let error as ShouError {
                if error.code == "cancelled" { throw error }
                issues.append(StartupInventoryIssue(sourceId: location.id, path: location.path, code: error.code))
                sources.append(StartupSourceCoverage(location: location, status: "unavailable", entryCount: count, definitionCount: found))
            }
        }
        try checkCancellation()
        return StartupInventory(checkedAt: Date(), includeSystem: options.includeSystem, sources: sources,
            items: items.sorted { ($0.label, $0.path) < ($1.label, $1.path) }, issues: issues)
        #else
        throw ShouError("unsupported_platform", "Startup discovery is currently available only on macOS.")
        #endif
    }

    #if os(macOS)
    private func checkCancellation() throws {
        if Task.isCancelled { throw ShouError("cancelled", "Startup scan stopped.") }
    }
    private func parse(_ data: Data, location: StartupLocation, path: String) throws -> StartupDefinition {
        guard let dictionary=try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let label=dictionary["Label"] as? String, printable(label, limit: 512), !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ShouError("invalid_definition", "Startup definition is invalid.")
        }
        func boolean(_ key: String) throws -> Bool? {
            guard let value=dictionary[key] else { return nil }
            guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let result=value as? Bool else {
                throw ShouError("invalid_definition", "Startup definition is invalid.")
            }
            return result
        }
        let disabled=try boolean("Disabled") ?? false
        var triggers: [String]=[]
        if try boolean("RunAtLoad") == true { triggers.append("run_at_load") }
        if let keepAlive=dictionary["KeepAlive"] {
            if keepAlive is [String: Any] { triggers.append("conditional_keep_alive") }
            else if try boolean("KeepAlive") == true { triggers.append("keep_alive") }
        }
        for (key, trigger) in [("StartInterval", "scheduled"), ("StartCalendarInterval", "scheduled"), ("WatchPaths", "watched_paths"), ("QueueDirectories", "queued_directories"), ("Sockets", "socket_activation"), ("MachServices", "service_activation")] {
            if dictionary[key] != nil, !triggers.contains(trigger) { triggers.append(trigger) }
        }
        var program: String?
        if let value=dictionary["Program"] as? String { program=value }
        else if let values=dictionary["ProgramArguments"] as? [String] { program=values.first }
        if let value=program, (!value.hasPrefix("/") || !printable(value, limit: 4_096)) { program=nil }
        // Arguments and environment values may contain credentials; do not retain them.
        return StartupDefinition(sourceId: location.id, path: path, label: label, programPath: program, disabledByDefinition: disabled, triggers: triggers)
    }
    private func printable(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    #endif
}
