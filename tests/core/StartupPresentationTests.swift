import Foundation
import ShouCore

func startupGroupsUseExactApplicationIdentityAndPreserveMixedStates() throws {
    let first=StartupDefinition(sourceId: "macos.user_agents", path: "/fixture/first.plist", label: "dev.example.agent",
        programPath: "/Applications/Example.app/Contents/MacOS/Agent", disabledByDefinition: false, triggers: [],
        configuredState: "enabled", controlCapability: "launchctl_user_agent", displayName: "Example", applicationPath: "/Applications/Example.app")
    let second=StartupDefinition(sourceId: "macos.local_agents", path: "/fixture/second.plist", label: "dev.example.updater",
        programPath: nil, disabledByDefinition: false, triggers: [], configuredState: "disabled", displayName: "Example Updater", applicationPath: "/Applications/Example.app")
    let different=StartupDefinition(sourceId: "fixture", path: "/fixture/different.plist", label: "dev.other.agent",
        programPath: nil, disabledByDefinition: false, triggers: [], displayName: "Example", applicationPath: "/fixture/Other.app")
    let groups=StartupPresentation.groups([first, second, different])
    try expect(groups.count == 2)
    let group=try require(groups.first { $0.applicationPath == "/Applications/Example.app" })
    try expect(group.items.count == 2 && group.configuredState == "mixed")
    try expect(group.controllableItems == [first])
    try expect(!StartupFilter.enabled.matches(group) && !StartupFilter.disabled.matches(group))
    try expect(group.matches(query: " DEV.EXAMPLE.UPDATER "))
    try expect(group.matches(query: "/fixture/second.plist"))
    try expect(!group.matches(query: "unrelated"))
}

func startupFiltersKeepUnknownAndMissingTargetsDistinct() throws {
    let missing=StartupDefinition(sourceId: "fixture", path: "/fixture/missing.plist", label: "Missing",
        programPath: "/fixture/missing", disabledByDefinition: false, triggers: [], configuredState: "disabled", targetState: "missing")
    let unknown=StartupDefinition(sourceId: "fixture", path: "/fixture/unknown.plist", label: "Unknown",
        programPath: nil, disabledByDefinition: true, triggers: [])
    let enabled=StartupDefinition(sourceId: "fixture", path: "/fixture/enabled.plist", label: "Enabled",
        programPath: "/usr/bin/true", disabledByDefinition: false, triggers: [], configuredState: "enabled", publisher: "Example Publisher", targetState: "exists")
    let groups=StartupPresentation.groups([missing, unknown, enabled])
    try expect(groups.filter(StartupFilter.all.matches).count == 3)
    try expect(groups.filter(StartupFilter.enabled.matches).count == 1)
    try expect(groups.filter(StartupFilter.disabled.matches).count == 1)
    try expect(groups.filter(StartupFilter.leftover.matches).map(\.name) == ["Missing"])
    let unknownGroup=try require(groups.first { $0.name == "Unknown" })
    try expect(unknownGroup.configuredState == "unknown" && unknownGroup.controllableItems.isEmpty)
    try expect(!StartupFilter.leftover.matches(unknownGroup))
    try expect(groups.contains { $0.matches(query: "publisher") })
    try expect(StartupPresentation.groups([]).isEmpty)
}
