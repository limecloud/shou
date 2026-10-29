import Foundation

public struct ApplicationShortcutSnapshot: Codable, Sendable {
    public let identity: FileEntry
    public let parentIdentity: FileEntry
    public let currentUser: UInt32
    public let requiresAdministrator: Bool
    public init(identity: FileEntry, parentIdentity: FileEntry, currentUser: UInt32, requiresAdministrator: Bool) {
        self.identity=identity; self.parentIdentity=parentIdentity; self.currentUser=currentUser; self.requiresAdministrator=requiresAdministrator
    }
}

extension ShouEngine {
    func reviewApplicationShortcut(_ app: ApplicationDefinition, configuration: Configuration, budget: ScanBudget) throws -> ApplicationUninstallReview {
        let snapshot=try filesystem.applicationShortcut(app.path)
        guard !app.isSystemApplication, snapshot.identity.metadata == app.identity else {
            throw ShouError("plan_stale", "The shortcut changed. Check this application again.")
        }
        let manifest=[snapshot.identity]
        guard !uninstallExcluded(target: app.path, manifest: manifest, configuration: configuration, caseSensitive: filesystem.caseSensitivePaths),
              !store.protectedPaths.contains(where: { app.path == $0 || app.path.hasPrefix($0 + "/") || $0.hasPrefix(app.path + "/") }) else {
            throw ShouError("protected_content", "This application component is protected or excluded.")
        }
        var warnings=["Only this broken shortcut is removed. Its target and associated data are kept."]
        if snapshot.requiresAdministrator { warnings += ["administrator_authorization_required", "administrator_permanent_removal_available"] }
        let origin=UninstallReceiptOrigin(kind: .shortcut, applicationPath: app.path, bundleIdentifier: nil,
            parentPath: URL(fileURLWithPath: app.path).deletingLastPathComponent().path, parentIdentity: snapshot.parentIdentity)
        let component=UninstallComponent(id: Digest.sha256(Data(("shortcut\0" + app.path).utf8)), kind: .shortcut, path: app.path,
            status: "complete", origin: origin, manifest: manifest, allocatedBytesEstimate: max(0, snapshot.identity.allocatedBytes), reasons: [], warnings: warnings)
        return ApplicationUninstallReview(id: Codec.id("appreview"), application: app, checkedAt: now(), configurationDigest: try Digest.of(configuration),
            components: [component], limitations: warnings, budget: budget)
    }
}
