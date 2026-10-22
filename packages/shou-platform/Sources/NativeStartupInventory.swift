import Foundation
import ShouCore
#if os(macOS)
import Darwin
import CoreFoundation
#endif

/// Pure parsers for `launchctl` output. They are kept separate from process
/// execution so state semantics can be verified without changing startup items.
public enum LaunchctlStateParser {
    public static func configuredStates(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let value=String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("\""), let closing=value.dropFirst().firstIndex(of: "\"") else { continue }
            let label=String(value[value.index(after: value.startIndex)..<closing])
            let remainder=value[value.index(after: closing)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard remainder.hasPrefix("=>") else { continue }
            let state=remainder.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";,"))
            guard !label.isEmpty else { continue }
            if ["enabled", "false"].contains(state) { result[label]="enabled" }
            if ["disabled", "true"].contains(state) { result[label]="disabled" }
        }
        return result
    }

    public static func configuredState(label: String, disabledByDefinition: Bool, overrides: [String: String]?) -> String {
        guard let overrides else { return "unknown" }
        return overrides[label] ?? (disabledByDefinition ? "disabled" : "enabled")
    }

    public static func disabledOverrides(_ output: String) -> [String: String]? {
        guard output.contains("disabled services = {"), output.contains("}") else { return nil }
        let result=configuredStates(output)
        for line in output.split(whereSeparator: \.isNewline) where line.contains("=>") {
            guard configuredStates(String(line)).count == 1 else { return nil }
        }
        return result
    }

    public static func runtimeState(status: Int32, output: String) -> String {
        guard status == 0 else {
            let lower=output.lowercased()
            if lower.contains("could not find service") || lower.contains("service not found") || lower.contains("no such process") {
                return "not_loaded"
            }
            return "unknown"
        }
        return output.lowercased().contains("state = running") ? "running" : "loaded"
    }
}

public struct NativeStartupInventory: StartupInventoryReading {
    public static let maximumDefinitionBytes=262_144
    private let locations: [StartupLocation]
    private let homeDirectory: URL
    private let includeRegistrations: Bool
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, locations: [StartupLocation]? = nil) {
        self.homeDirectory=homeDirectory; self.includeRegistrations=locations == nil
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
                let knownAgent=["macos.user_agents", "macos.local_agents"].contains(location.id)
                let knownDaemon=location.id == "macos.local_daemons" || location.id == "macos.system_daemons"
                let launchctl=knownAgent || knownDaemon ? LaunchctlSession(domain: knownAgent ? "gui/\(getuid())" : "system", deadline: deadline) : nil
                if (knownAgent || knownDaemon) && launchctl?.configured == nil {
                    issues.append(StartupInventoryIssue(sourceId: location.id, path: location.path, code: "state_unavailable"))
                }
                for name in listing.names where name.hasSuffix(".plist") {
                    try checkCancellation()
                    if ContinuousClock.now >= deadline {
                        issues.append(StartupInventoryIssue(sourceId: location.id, path: location.path, code: "resource_limit")); break
                    }
                    let path=location.path + "/" + name
                    do {
                        let data=try NativeDefinitionFiles.bytes(directory: directory, name: name, path: path, deadline: deadline)
                        let label=labelFromData(data)
                        let runtime=launchctl?.runtimeState(for: label)
                        items.append(try parse(data, location: location, path: path, overrides: launchctl?.configured, runtimeState: runtime, deadline: deadline)); found += 1
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
        var unavailable=["login_items", "background_task_registrations", "embedded_helpers"]
        if includeRegistrations {
            let registrations=try NativeStartupRegistrations.read(homeDirectory: homeDirectory, limit: options.maxEntries-visited, deadline: deadline)
            sources += registrations.sources; items += registrations.items; issues += registrations.issues
            unavailable=registrations.unavailable + ["embedded_helpers"]
        }
        try checkCancellation()
        return StartupInventory(checkedAt: Date(), includeSystem: options.includeSystem, sources: sources,
            items: items.sorted { ($0.label, $0.path) < ($1.label, $1.path) }, issues: issues,
            scope: includeRegistrations ? "macos_startup_items" : "launchd_definitions", unavailableSources: unavailable)
        #elseif os(Windows)
        return try WindowsStartupInventory().read(options: options)
        #else
        throw ShouError("unsupported_platform", "Startup discovery is currently available only on macOS.")
        #endif
    }

    #if os(macOS)
    private func checkCancellation() throws {
        if Task.isCancelled { throw ShouError("cancelled", "Startup scan stopped.") }
    }
    private func parse(_ data: Data, location: StartupLocation, path: String, overrides: [String: String]? = nil, runtimeState: String? = nil, deadline: ContinuousClock.Instant) throws -> StartupDefinition {
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
        let capability=NativeStartupControl.capability(path:path,label:label,sourceId:location.id,homeDirectory:homeDirectory,deadline:deadline)
        let associated=(dictionary["AssociatedBundleIdentifiers"] as? String) ?? (dictionary["AssociatedBundleIdentifiers"] as? [String]).flatMap { $0.count == 1 ? $0.first : nil }
        let identity=NativeStartupMetadata.identity(program: program, associatedBundle: associated, deadline: deadline)
        let removable=location.id == "macos.user_agents" && capability == "launchctl_user_agent"
        return StartupDefinition(sourceId: location.id, path: path, label: label, programPath: program, disabledByDefinition: disabled, triggers: triggers,
            configuredState: LaunchctlStateParser.configuredState(label: label, disabledByDefinition: disabled, overrides: overrides), runtimeState: runtimeState ?? "unknown", controlCapability: capability,
            displayName: identity.name, applicationPath: identity.application, targetState: NativeStartupMetadata.targetState(program), removable: removable)
    }
    private func labelFromData(_ data: Data) -> String {
        guard let dictionary=try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let label=dictionary["Label"] as? String else { return "" }
        return label
    }
    private func printable(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    #endif
}

#if os(macOS)
private struct LaunchctlSession {
    let domain: String
    let configured: [String: String]?
    let deadline: ContinuousClock.Instant

    init?(domain: String, deadline: ContinuousClock.Instant) {
        guard ContinuousClock.now < deadline else { return nil }
        self.domain=domain
        self.deadline=deadline
        guard let result=try? NativeStartupCommand.run(["print-disabled", domain], deadline: deadline), result.status == 0,
              let states=LaunchctlStateParser.disabledOverrides(result.output) else {
            self.configured=nil
            return
        }
        self.configured=states
    }

    func runtimeState(for label: String) -> String? {
        guard !label.isEmpty, ContinuousClock.now < deadline,
              let result=try? NativeStartupCommand.run(["print", domain + "/" + label], deadline: deadline) else { return "unknown" }
        return LaunchctlStateParser.runtimeState(status: result.status, output: result.output)
    }

}
#endif
