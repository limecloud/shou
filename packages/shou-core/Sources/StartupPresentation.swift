import Foundation

public enum StartupFilter: String, CaseIterable, Sendable {
    case all, enabled, disabled, leftover

    public func matches(_ group: StartupApplicationGroup) -> Bool {
        switch self {
        case .all: true
        case .enabled: group.configuredState == "enabled"
        case .disabled: group.configuredState == "disabled"
        case .leftover: group.items.contains { $0.targetState == "missing" }
        }
    }
}

/// Groups only identities established by the reader. Similar names and reverse
/// DNS prefixes are not sufficient evidence that registrations share an owner.
public struct StartupApplicationGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let applicationPath: String?
    public let publisher: String?
    public let items: [StartupDefinition]

    public var configuredState: String {
        let states=Set(items.map(\.configuredState))
        if states == ["enabled"] { return "enabled" }
        if states == ["disabled"] { return "disabled" }
        if states.isSubset(of: ["enabled", "disabled"]) { return "mixed" }
        return "unknown"
    }

    public var controllableItems: [StartupDefinition] {
        items.filter {
            ["launchctl_user_agent", "launchctl_system_daemon", "login_item", "windows_user_task"].contains($0.controlCapability) &&
                ["enabled", "disabled"].contains($0.configuredState)
        }
    }

    public func matches(query: String) -> Bool {
        let text=query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || ([name, publisher ?? ""] + items.flatMap {
            [$0.label, $0.path, $0.programPath ?? "", $0.publisher ?? ""]
        }).contains { $0.localizedStandardContains(text) }
    }
}

public enum StartupPresentation {
    public static func groups(_ items: [StartupDefinition]) -> [StartupApplicationGroup] {
        let grouped=Dictionary(grouping: items) { item in
            if let path=item.applicationPath { return "application:" + path }
            return item.sourceId.hasPrefix("windows.") ? "registration:" + item.id : "label:" + item.label
        }
        return grouped.map { key, definitions in
            let sorted=definitions.sorted { ($0.sourceId, $0.path) < ($1.sourceId, $1.path) }
            let first=sorted[0]
            return StartupApplicationGroup(id: key,
                name: sorted.compactMap(\.displayName).first ?? first.label,
                applicationPath: first.applicationPath,
                publisher: sorted.compactMap(\.publisher).first,
                items: sorted)
        }.sorted {
            let order=$0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
