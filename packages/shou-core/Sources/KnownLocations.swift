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
    public init(locations: [KnownLocation], snapshots: [ScanSnapshot], issues: [KnownLocationIssue], skippedLocationIds: [String]) {
        self.locations=locations; self.snapshots=snapshots; self.issues=issues; self.skippedLocationIds=skippedLocationIds
    }
    public var status: String { issues.isEmpty && snapshots.allSatisfy { $0.status == "complete" } ? "complete" : "partial" }
}

public enum KnownLocations {
    static func pathKey(_ value: String, platform: String) -> String {
        guard platform == "windows" else { return value }
        var path=value.replacingOccurrences(of: "\\", with: "/")
        if path.range(of: "^/[A-Za-z]:/", options: .regularExpression) != nil { path.removeFirst() }
        while path.hasSuffix("/"), path.count > 3 { path.removeLast() }
        return path.lowercased()
    }
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
        guard Set(values.map { $0.platform + ":" + $0.relativePath }).count == values.count else { throw ShouError("invalid_rule", "Built-in location paths must be unique per platform.") }
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
    private struct ScopedDefinition: Sendable {
        let definition: Definition
        let ruleIds: [String]
        let bundleIdentifiers: [String]
    }
    /// Validate immutable resource relationships once. Paths and filesystem
    /// availability remain specific to each caller and are never cached here.
    private static let scopedDefinitions: Result<[ScopedDefinition], Error> = Result {
        let templates=try BuiltinCatalog.templates()
        let values=try definitions.get()
        for template in templates where template.location != "projects" {
            guard template.supportedPlatforms.allSatisfy({ supported in values.contains { $0.id == template.location && $0.platform == supported } }) else {
                throw ShouError("invalid_rule", "A built-in rule has no platform-scoped scan location.", details: ["rule": template.id, "location": template.location])
            }
        }
        return try values.map { definition in
            let rules=templates.filter { $0.location == definition.id && $0.supportedPlatforms.contains(definition.platform) }
            guard !rules.isEmpty else { throw ShouError("invalid_rule", "A built-in scan location has no scoped rules.", details: ["location": definition.id]) }
            return ScopedDefinition(definition: definition, ruleIds: rules.map(\.id),
                bundleIdentifiers: Set(rules.flatMap { $0.applicationBundleIdentifiers ?? [] }).sorted())
        }
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

    /// Platform-scoped explicit roots; availability is checked by the platform adapter.
    public static func catalog(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, platform: String = currentPlatform) throws -> [KnownLocation] {
        try scopedDefinitions.get().filter { $0.definition.platform == platform }.map { scoped in
            let definition=scoped.definition
            let path=homeDirectory.appendingPathComponent(definition.relativePath, isDirectory: true).path
            return KnownLocation(id: definition.id, title: definition.title, path: path,
                ruleIds: scoped.ruleIds, category: definition.category,
                applicationBundleIdentifiers: scoped.bundleIdentifiers, exists: false, availabilityIssue: nil)
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
        let key=KnownLocations.pathKey(location.path, platform: filesystem.platform)
        if let existing=try configuration().workspaces.first(where: { KnownLocations.pathKey($0.path, platform: filesystem.platform) == key }) { return existing }
        return try addWorkspace(path: location.path, rootRef: "shou-location-" + location.id)
    }

    public func scan(locationId: String, ruleIds: [String] = [], scope: ScanScope = .full, budget: ScanBudget = ScanBudget(), progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanSnapshot {
        try validateKnownLocationBudget(budget)
        let workspace=try workspaceForKnownLocation(locationId)
        return try scan(workspaceId: workspace.id, ruleIds: ruleIds, scope: scope, budget: budget, progress: progress)
    }

    /// Register all existing roots before capturing evidence so the registrations
    /// themselves cannot invalidate earlier snapshots in this batch.
    public func scanKnownLocations(includeProjects: Bool = false, budget: ScanBudget = ScanBudget(), maxConcurrentLocations: Int = 4, progress: @escaping @Sendable (KnownLocation, ScanProgress) -> Void = { _, _ in }) async throws -> SystemScanResult {
        try validateKnownLocationBudget(budget)
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        guard (1...4).contains(maxConcurrentLocations) else { throw ShouError("invalid_argument", "Cleanup scan concurrency must be between one and four.") }
        maintainDerivedRecordsIfNeeded()
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
        let prepared=registered
        let reporter=BatchScanProgress(count: prepared.count, output: progress)
        let workers=min(maxConcurrentLocations, max(1, filesystem.maximumConcurrentReadOperations), max(1, ProcessInfo.processInfo.activeProcessorCount))
        let completed=try await withThrowingTaskGroup(of: (Int, ScanSnapshot?, ShouError?).self) { group in
            func enqueue(_ index: Int) {
                let (location, workspace)=prepared[index]
                group.addTask {
                    reporter.report(ScanProgress(stage: "scanning", entryCount: 0, currentPath: location.path), index: index, location: location)
                    do {
                        let snapshot=try await self.scanWorker(workspaceId: workspace.id, budget: budget, progress: {
                            reporter.report($0, index: index, location: location)
                        })
                        return (index, snapshot, nil)
                    } catch {
                        let failure=error as? ShouError ?? ShouError("io_error", error.localizedDescription)
                        if Task.isCancelled || failure.code == "cancelled" { throw ShouError("cancelled", "Scan cancelled.") }
                        reporter.report(ScanProgress(stage: "saving", entryCount: 0, currentPath: location.path,
                            completedUnitCount: 3, totalUnitCount: 3), index: index, location: location)
                        return (index, nil, failure)
                    }
                }
            }
            var next=0
            while next < min(workers, prepared.count) { enqueue(next); next += 1 }
            var values=[(Int, ScanSnapshot?, ShouError?)]()
            while let value=try await group.next() {
                values.append(value)
                if next < prepared.count { enqueue(next); next += 1 }
            }
            return values.sorted { $0.0 < $1.0 }
        }
        var snapshots=[ScanSnapshot]()
        for (index, snapshot, failure) in completed {
            let location=prepared[index].0
            if let failure { issues.append(KnownLocationIssue(locationId: location.id, code: failure.code, message: failure.message)) }
            guard let snapshot else { continue }
            snapshots.append(snapshot)
            if snapshot.status != "complete" {
                issues.append(KnownLocationIssue(locationId: location.id, code: "partial_result", message: "Some paths could not be fully scanned. Only independently verified items can be reviewed for cleanup."))
            }
            for issue in snapshot.issues where issue.hasPrefix(InstalledApplicationCaches.issuePrefix) {
                let code=String(issue.dropFirst(InstalledApplicationCaches.issuePrefix.count))
                let message: String
                switch code {
                case "application_discovery_incomplete": message="Installed application cache discovery is incomplete. Caches without verified ownership were not included."
                case "ambiguous_application_owner": message="Some installed applications share a bundle identifier. Their caches were not included."
                default: message="Installed application cache discovery is unavailable. Maintained cleanup rules remain available."
                }
                issues.append(KnownLocationIssue(locationId: location.id, code: code, message: message))
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
