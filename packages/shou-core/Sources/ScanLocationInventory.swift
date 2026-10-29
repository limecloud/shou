import Foundation

public struct ScanLocationEntry: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let path: String
    public let category: String
    public let origin: String
    public let workspaceId: String?
    public let canRemove: Bool
    public let availability: String
    public let issue: String?
}

public struct ScanLocationInventory: Codable, Sendable {
    public let configurationRevision: String
    public let entries: [ScanLocationEntry]
}

extension ShouEngine {
    /// Metadata-only scope inspection. Removal eligibility refers to saved
    /// configuration, never ownership or permission to remove target files.
    public func scanLocations() throws -> ScanLocationInventory {
        let config=try configuration()
        var entries=[ScanLocationEntry]()
        for location in try projectLocations() {
            try Task.checkCancellation()
            let workspace=config.workspaces.first { $0.id == location.id }
            let automatic=try (workspace?.rootRef.hasPrefix("shou-location-project-") == true || ProjectLocations.isConventional(location.path, homeDirectory: homeDirectory, platform: filesystem.platform))
            var availability=location.exists ? "available" : "unavailable", issue=location.availabilityIssue
            if workspace != nil {
                switch filesystem.locationAvailability(location.path) {
                case .available: availability="available"
                case .missing: availability="missing"
                case .unavailable(let message): availability="unavailable"; issue=message
                }
            }
            entries.append(ScanLocationEntry(id: location.id, title: location.title, path: location.path, category: location.category,
                origin: automatic || workspace == nil ? "automatic" : "included", workspaceId: workspace?.id,
                canRemove: workspace != nil && !automatic, availability: availability, issue: issue))
        }
        for location in try knownLocations() where location.exists || location.availabilityIssue != nil {
            try Task.checkCancellation()
            entries.append(ScanLocationEntry(id: location.id, title: location.title, path: location.path, category: location.category,
                origin: "builtin", workspaceId: nil, canRemove: false, availability: location.exists ? "available" : "unavailable", issue: location.availabilityIssue))
        }
        return ScanLocationInventory(configurationRevision: config.revision, entries: entries)
    }
}
