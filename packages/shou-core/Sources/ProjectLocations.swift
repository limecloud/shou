import Foundation

/// Conventional project collections are discovery hints, never deletion rules.
public enum ProjectLocations {
    public static let relativePaths = [
        "Developer", "Projects", "Code", "code", "dev", "src", "repos", "GitHub",
        "Workspace", "Workspaces", "workspace", "workspaces", "Development", "Source", "Sources", "Git", "Repos",
        "Documents/Developer", "Documents/Projects", "Documents/Code", "Documents/dev", "Documents/GitHub",
        "Documents/Workspace", "Documents/Workspaces", "Documents/Development", "Documents/repos", "Documents/src",
        "Desktop/Projects", "Desktop/Code", "Desktop/dev"
    ]
}

extension ShouEngine {
    /// Reads metadata only. Explicit registrations take precedence over an
    /// overlapping suggestion so discovery cannot bypass their rule policy.
    public func projectLocations() throws -> [KnownLocation] {
        guard ["macos", "windows"].contains(filesystem.platform) else { return [] }
        let caseSensitive=filesystem.platform != "windows"
        let cachePaths=Set(try KnownLocations.catalog(homeDirectory: homeDirectory, platform: filesystem.platform).map { KnownLocations.pathKey($0.path, platform: filesystem.platform) })
        let roots=try configuration().workspaces.filter { !cachePaths.contains(KnownLocations.pathKey($0.path, platform: filesystem.platform)) }
        var locations=roots.map { projectLocation(path: $0.path, id: $0.id) }
        var identities=roots.map(\.identity)
        for relative in ProjectLocations.relativePaths {
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            let path=homeDirectory.appendingPathComponent(relative, isDirectory: true).path
            guard !locations.contains(where: { Self.projectPathsOverlap($0.path, path, caseSensitive: caseSensitive) }) else { continue }
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
                    locations.append(projectLocation(path: path, issue: error.localizedDescription))
                }
            }
        }
        return locations
    }

    private static func projectPathsOverlap(_ first: String, _ second: String, caseSensitive: Bool) -> Bool {
        let a=caseSensitive ? first : first.lowercased(), b=caseSensitive ? second : second.lowercased()
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private func projectLocation(path: String, id: String? = nil, issue: String? = nil) -> KnownLocation {
        KnownLocation(id: id ?? "project-" + String(Digest.sha256(Data(path.utf8)).suffix(20)),
            title: "Developer Projects", path: path, ruleIds: [], category: "build", applicationBundleIdentifiers: [],
            exists: issue == nil, availabilityIssue: issue)
    }
}
