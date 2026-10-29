import Foundation

/// Conventional project collections are discovery hints, never deletion rules.
public enum ProjectLocations {
    private static let definitions: Result<[String], Error> = Result {
        guard let url=CoreResources.bundle.url(forResource: "project-locations", withExtension: "json") else {
            throw ShouError("io_error", "Project location hints are unavailable.")
        }
        let paths=try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        guard !paths.isEmpty, paths.count <= 64, Set(paths).count == paths.count else {
            throw ShouError("invalid_rule", "Project location hints are invalid.")
        }
        for path in paths {
            try PathPattern.validate(path)
            guard !path.contains("*"), !path.contains("?") else { throw ShouError("invalid_rule", "Project location hints must be exact relative paths.") }
        }
        return paths
    }
    public static var relativePaths: [String] { get throws { try definitions.get() } }

    public static func isConventional(_ path: String, homeDirectory: URL, platform: String) throws -> Bool {
        try relativePaths.contains { pathsOverlap(path, homeDirectory.appendingPathComponent($0).path, platform: platform) }
    }
    static func pathsOverlap(_ first: String, _ second: String, platform: String) -> Bool {
        let a=KnownLocations.pathKey(first, platform: platform), b=KnownLocations.pathKey(second, platform: platform)
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
}

extension ShouEngine {
    /// Reads metadata only. Explicit registrations take precedence over an
    /// overlapping suggestion so discovery cannot bypass their rule policy.
    public func projectLocations(scope: CleanupScanScope = .standard) throws -> [KnownLocation] {
        guard filesystem.platform == "macos" else { return [] }
        let cachePaths=Set(try KnownLocations.catalog(homeDirectory: homeDirectory, platform: filesystem.platform).map { KnownLocations.pathKey($0.path, platform: filesystem.platform) })
        let saved=try configuration().workspaces
        let roots: [Workspace]
        var selectedVolumeRoots=Set<String>()
        var candidates=[String]()
        var discoveryIssues=[KnownLocation]()
        let deadline=ContinuousClock.now.advanced(by: .seconds(10))
        var listings=0
        func children(_ path: String) throws -> [String] {
            guard let cleanupLocations else { return [] }
            guard listings < 128, ContinuousClock.now < deadline else {
                discoveryIssues.append(projectLocation(path: path, issue: "Some scan locations could not be discovered within the limit.")); return []
            }
            listings += 1
            do {
                let listing=try cleanupLocations.childDirectories(path)
                if !listing.complete || listing.paths.count > 4_096 { discoveryIssues.append(projectLocation(path: path, issue: "Some scan locations could not be discovered within the limit.")) }
                return listing.paths.prefix(4_096).filter { child in
                    URL(fileURLWithPath: child).deletingLastPathComponent().path == path &&
                    !URL(fileURLWithPath: child).lastPathComponent.hasPrefix(".")
                }.sorted()
            } catch {
                if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
                discoveryIssues.append(projectLocation(path: path, issue: error.localizedDescription))
                return []
            }
        }
        func standardCandidates() throws -> [String] {
            if cleanupLocations == nil { return try ProjectLocations.relativePaths.map { homeDirectory.appendingPathComponent($0).path } }
            return try children(homeDirectory.path).filter { candidate in
                !cachePaths.contains { ProjectLocations.pathsOverlap($0, candidate, platform: filesystem.platform) }
                && !["Applications", "Library"].contains(URL(fileURLWithPath: candidate).lastPathComponent)
            }
        }
        switch scope {
        case .standard:
            roots=saved.filter { !cachePaths.contains(KnownLocations.pathKey($0.path, platform: filesystem.platform)) }
            candidates=try standardCandidates()
        case .folders(let paths):
            guard !paths.isEmpty, paths.count <= 256 else { throw ShouError("invalid_argument", "Choose between one and 256 scan folders.") }
            candidates=try paths.map { try filesystem.normalizedPath($0) }
            roots=saved.filter { root in candidates.contains { root.path == $0 || root.path.hasPrefix($0 + "/") } }
        case .volumes(let paths):
            guard paths.count <= 32, let cleanupLocations else { throw ShouError("invalid_argument", "Choose available local disks.") }
            let volumes=try cleanupLocations.localVolumes()
            guard paths.allSatisfy({ path in volumes.contains { $0.path == path } }) else { throw ShouError("plan_stale", "A selected disk is no longer available.") }
            roots=saved.filter { !cachePaths.contains(KnownLocations.pathKey($0.path, platform: filesystem.platform)) }
            selectedVolumeRoots=Set(volumes.filter { paths.contains($0.path) && !$0.isSystem }.map(\.path))
            candidates=try standardCandidates() + selectedVolumeRoots.sorted()
        }
        var locations=roots.map { projectLocation(path: $0.path, id: $0.id) }
        var identities=roots.map(\.identity)
        var next=0, inspected=0
        let protectedScopes=saved.map(\.path)
        while next < candidates.count {
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            let path=candidates[next]; next += 1
            if locations.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) { continue }
            if protectedScopes.contains(where: { path.hasPrefix($0 + "/") }) {
                discoveryIssues.append(projectLocation(path: path, issue: "This folder is inside a saved scan location. Scan that location to preserve its rules and exclusions.")); continue
            }
            // Split ancestors around saved scopes instead of bypassing their
            // disabled rules/exclusions or losing every unregistered sibling.
            if protectedScopes.contains(where: { $0.hasPrefix(path + "/") }) {
                guard inspected < 128 else { discoveryIssues.append(projectLocation(path: path, issue: "Some scan locations could not be discovered within the limit.")); continue }
                inspected += 1; candidates.append(contentsOf: try children(path)); continue
            }
            guard locations.count < 256 else {
                discoveryIssues.append(projectLocation(path: path, issue: "Some scan locations could not be discovered within the limit.")); break
            }
            switch filesystem.locationAvailability(path) {
            case .missing: continue
            case .unavailable(let message):
                locations.append(projectLocation(path: path, issue: message))
            case .available:
                do {
                    let identity=try filesystem.rootIdentity(path)
                    guard !identities.contains(where: { $0.sameObject(as: identity) }) else { continue }
                    identities.append(identity)
                    locations.append(projectLocation(path: path))
                } catch {
                    if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
                    if selectedVolumeRoots.contains(path) { candidates.append(contentsOf: try children(path)) }
                    locations.append(projectLocation(path: path, issue: error.localizedDescription))
                }
            }
        }
        var seen=Set<String>()
        return (locations + discoveryIssues).filter { seen.insert($0.id).inserted }
    }

    private func projectLocation(path: String, id: String? = nil, issue: String? = nil) -> KnownLocation {
        KnownLocation(id: id ?? "project-" + String(Digest.sha256(Data(path.utf8)).suffix(20)) + (issue == nil ? "" : "-unavailable"),
            title: "Developer Projects", path: path, ruleIds: [], category: "build", applicationBundleIdentifiers: [],
            exists: issue == nil, availabilityIssue: issue)
    }
}
