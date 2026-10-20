import Foundation

/// A discoverable, explicit scan root. Existence does not grant read or cleanup permission.
public struct KnownLocation: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let path: String
    public let ruleIds: [String]
    public let category: String
    public let applicationBundleIdentifiers: [String]
    public let exists: Bool
    public let availabilityIssue: String?
}

public struct KnownLocationIssue: Codable, Sendable {
    public let locationId: String
    public let code: String
    public let message: String
}

public struct SystemScanResult: Sendable {
    public let locations: [KnownLocation]
    public let snapshots: [ScanSnapshot]
    public let issues: [KnownLocationIssue]
    public let skippedLocationIds: [String]
    public var status: String { issues.isEmpty && snapshots.allSatisfy { $0.status == "complete" } ? "complete" : "partial" }
}

public enum KnownLocations {
    private struct Definition: Decodable, Sendable {
        let id: String
        let title: String
        let category: String
        let relativePath: String
        let platform: String
    }
    private static let definitions: Result<[Definition], Error> = Result {
        guard let url=CoreResources.bundle.url(forResource: "known-locations", withExtension: "json") else { throw ShouError("io_error", "Built-in scan locations are unavailable.") }
        let values=try JSONDecoder().decode([Definition].self, from: Data(contentsOf: url))
        guard Set(values.map { $0.platform + ":" + $0.id }).count == values.count else { throw ShouError("invalid_rule", "Built-in location identifiers must be unique per platform.") }
        for value in values {
            try PathPattern.validate(value.relativePath)
            guard value.id.range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  ["macos", "windows"].contains(value.platform), ["application", "browser", "developer", "system"].contains(value.category),
                  !value.relativePath.contains("*"), !value.relativePath.contains("?"),
                  !["Library", "Library/Application Support", "Library/Containers"].contains(value.relativePath) else {
                throw ShouError("invalid_rule", "Built-in scan location metadata is invalid.")
            }
        }
        return values
    }
    public static var currentPlatform: String {
        #if os(macOS)
        "macos"
        #elseif os(Windows)
        "windows"
        #else
        "unsupported"
        #endif
    }

    /// Windows roots will be added with a Windows filesystem adapter and verified rules.
    public static func catalog(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, platform: String = currentPlatform) throws -> [KnownLocation] {
        let templates=try BuiltinCatalog.templates()
        return try definitions.get().filter { $0.platform == platform }.map { definition in
            let path=homeDirectory.appendingPathComponent(definition.relativePath, isDirectory: true).path
            let rules=templates.filter { $0.location == definition.id }
            guard !rules.isEmpty else { throw ShouError("invalid_rule", "A built-in scan location has no scoped rules.", details: ["location": definition.id]) }
            return KnownLocation(id: definition.id, title: definition.title, path: path,
                ruleIds: rules.map(\.id), category: definition.category,
                applicationBundleIdentifiers: Set(rules.flatMap { $0.applicationBundleIdentifiers ?? [] }).sorted(), exists: false, availabilityIssue: nil)
        }
    }
}

extension ShouEngine {
    public func knownLocations() throws -> [KnownLocation] {
        try KnownLocations.catalog(homeDirectory: homeDirectory, platform: filesystem.platform).map { location in
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            let exists: Bool
            let issue: String?
            switch filesystem.locationAvailability(location.path) {
            case .available: exists=true; issue=nil
            case .missing: exists=false; issue=nil
            case .unavailable(let message): exists=false; issue=message
            }
            return KnownLocation(id: location.id, title: location.title, path: location.path, ruleIds: location.ruleIds, category: location.category,
                applicationBundleIdentifiers: location.applicationBundleIdentifiers, exists: exists, availabilityIssue: issue)
        }
    }

    /// Reuses a previously registered root, preserving its exclusions and disabled bindings.
    /// Registration uses the same identity and ownership checks as an explicitly chosen root.
    public func workspaceForKnownLocation(_ locationId: String) throws -> Workspace {
        guard let location=try KnownLocations.catalog(homeDirectory: homeDirectory, platform: filesystem.platform).first(where: { $0.id == locationId }) else {
            throw ShouError("invalid_argument", "Unknown built-in scan location.", details: ["location": locationId])
        }
        return try workspaceForKnownLocation(location)
    }

    private func workspaceForKnownLocation(_ location: KnownLocation) throws -> Workspace {
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        if let existing=try configuration().workspaces.first(where: { $0.path == location.path }) { return existing }
        return try addWorkspace(path: location.path, rootRef: "shou-location-" + location.id)
    }

    public func scan(locationId: String, ruleIds: [String] = [], scope: ScanScope = .full, budget: ScanBudget = ScanBudget(), progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanSnapshot {
        try validateKnownLocationBudget(budget)
        let workspace=try workspaceForKnownLocation(locationId)
        return try scan(workspaceId: workspace.id, ruleIds: ruleIds, scope: scope, budget: budget, progress: progress)
    }

    /// Register all existing roots before capturing evidence so the registrations
    /// themselves cannot invalidate earlier snapshots in this batch.
    public func scanKnownLocations(includeProjects: Bool = false, budget: ScanBudget = ScanBudget(), progress: @Sendable (KnownLocation, ScanProgress) -> Void = { _, _ in }) throws -> SystemScanResult {
        try validateKnownLocationBudget(budget)
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        let locations=try knownLocations() + (includeProjects ? projectLocations() : [])
        var registered: [(KnownLocation, Workspace)]=[]
        var issues=locations.compactMap { location in
            location.availabilityIssue.map { KnownLocationIssue(locationId: location.id, code: "access_unavailable", message: $0) }
        }
        for location in locations where location.exists {
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            progress(location, ScanProgress(stage: "preparing", entryCount: 0, currentPath: location.path))
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            do { registered.append((location, try workspaceForKnownLocation(location))) }
            catch {
                if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
                let failure=error as? ShouError ?? ShouError("io_error", error.localizedDescription)
                issues.append(KnownLocationIssue(locationId: location.id, code: failure.code, message: failure.message))
            }
        }
        var snapshots: [ScanSnapshot]=[]
        for (location, workspace) in registered {
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            do {
                let snapshot=try scan(workspaceId: workspace.id, scope: .cleanup, budget: budget, progress: { progress(location, $0) })
                snapshots.append(snapshot)
                if snapshot.status != "complete" {
                    issues.append(KnownLocationIssue(locationId: location.id, code: "partial_result", message: "Some paths could not be fully scanned. Only independently verified items can be reviewed for cleanup."))
                }
            } catch {
                let failure=error as? ShouError ?? ShouError("io_error", error.localizedDescription)
                if Task.isCancelled || failure.code == "cancelled" { throw ShouError("cancelled", "Scan cancelled.") }
                issues.append(KnownLocationIssue(locationId: location.id, code: failure.code, message: failure.message))
            }
        }
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        return SystemScanResult(locations: locations, snapshots: snapshots, issues: issues, skippedLocationIds: locations.filter { !$0.exists && $0.availabilityIssue == nil }.map(\.id))
    }

    private func validateKnownLocationBudget(_ budget: ScanBudget) throws {
        guard (1...1_000_000).contains(budget.maxEntries), budget.maxSeconds.isFinite, (1...600).contains(budget.maxSeconds), (1...128).contains(budget.maxDepth) else {
            throw ShouError("invalid_argument", "Scan budget is outside supported limits.")
        }
    }
}
