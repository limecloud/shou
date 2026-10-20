import Foundation

/// Installed application identity is immutable scan evidence, never deletion authority.
public struct InstalledApplicationCacheEvidence: Codable, Sendable, Equatable {
    public let ruleId: String
    public let application: ApplicationDefinition
}

enum InstalledApplicationCaches {
    static let prefix=BuiltinCatalog.prefix + "installed-cache."
    static let issuePrefix="installed_application_cache:"
    static let rebuildNote="The application will recreate its cache when needed."
    static let limitation="Only this installed application's exact bundle identifier cache is included. Application data and the application itself are retained."

    struct Discovery {
        var evidence: [InstalledApplicationCacheEvidence]=[]
        var rules: [CleanupRule]=[]
        var issues: [String]=[]
    }

    static func supports(_ workspace: Workspace, homeDirectory: URL, platform: String) -> Bool {
        platform == "macos" && workspace.path == homeDirectory.appendingPathComponent("Library/Caches").path
    }

    static func ruleId(_ identifier: String) -> String { prefix + Digest.sha256(Data(identifier.utf8)).replacingOccurrences(of: "sha256:", with: "") }

    static func valid(_ application: ApplicationDefinition) -> Bool {
        guard let identifier=application.bundleIdentifier else { return false }
        return ReceiptOrigins.validIdentifier(identifier) && !identifier.lowercased().hasPrefix("com.apple.") &&
            !application.source.systemOwned && application.identity.kind == "directory" &&
            application.path.lowercased().hasSuffix(".app") && application.infoDigest?.isEmpty == false
    }

    /// Even disabled static rules retain their narrower scope and cannot be bypassed.
    static func covered(_ identifier: String, by rules: [CleanupRule]) -> Bool {
        let path=[identifier.lowercased()]
        return rules.flatMap(\.match.relativePatterns).contains {
            let pattern=PathPattern.Compiled($0, caseSensitive: false)
            return pattern.matches(path) || pattern.couldMatchDescendant(of: path)
        }
    }

    static func rule(_ evidence: InstalledApplicationCacheEvidence, workspace: Workspace) throws -> CleanupRule {
        guard valid(evidence.application), let identifier=evidence.application.bundleIdentifier,
              evidence.ruleId == ruleId(identifier) else {
            throw ShouError("store_corrupt", "Installed application cache evidence is invalid.")
        }
        let title=evidence.application.name.isEmpty ? identifier : evidence.application.name
        let name=String(String.UnicodeScalarView(title.unicodeScalars.prefix(120)))
        return try BuiltinTemplate(id: evidence.ruleId, version: "1.0.0", name: name,
            category: "caches", patterns: [identifier], marker: nil, risk: "review", rebuildNote: rebuildNote,
            limitation: limitation, location: "caches", applicationBundleIdentifiers: [identifier], platforms: ["macos"]).rule(rootRef: workspace.rootRef)
    }

    static func discover(workspace: Workspace, homeDirectory: URL, platform: String,
                         catalog: any ApplicationCatalogReading, staticRules: [CleanupRule]) throws -> Discovery {
        guard supports(workspace, homeDirectory: homeDirectory, platform: platform) else { return Discovery() }
        let inventory: ApplicationCatalog
        do { inventory=try catalog.read(options: ApplicationCatalogOptions()) }
        catch {
            if Task.isCancelled || (error as? ShouError)?.code == "cancelled" { throw ShouError("cancelled", "Application discovery stopped.") }
            return Discovery(issues: [issuePrefix + "application_discovery_unavailable"])
        }
        // A partial inventory cannot establish that a bundle identifier has one owner.
        guard inventory.status == "complete" else { return Discovery(issues: [issuePrefix + "application_discovery_incomplete"]) }
        let grouped=Dictionary(grouping: inventory.items.filter { $0.bundleIdentifier != nil }, by: { $0.bundleIdentifier!.lowercased() })
        var result=Discovery()
        for application in inventory.items.sorted(by: { $0.path < $1.path }) {
            if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
            guard valid(application), let identifier=application.bundleIdentifier, !covered(identifier, by: staticRules) else { continue }
            guard grouped[identifier.lowercased()]?.count == 1 else {
                result.issues.append(issuePrefix + "ambiguous_application_owner"); continue
            }
            let evidence=InstalledApplicationCacheEvidence(ruleId: ruleId(identifier), application: application)
            result.evidence.append(evidence)
            result.rules.append(try rule(evidence, workspace: workspace))
        }
        result.issues=Array(Set(result.issues)).sorted()
        return result
    }

    static func selected(_ evidence: [InstalledApplicationCacheEvidence]?, ruleIds: [String]) throws -> [InstalledApplicationCacheEvidence] {
        let requested=Set(ruleIds.filter { $0.hasPrefix(prefix) })
        let selected=(evidence ?? []).filter { requested.contains($0.ruleId) }
        guard Set(selected.map(\.ruleId)) == requested, selected.count == requested.count else {
            throw ShouError("store_corrupt", "Installed application cache ownership evidence is missing or ambiguous.")
        }
        return selected.sorted { $0.ruleId < $1.ruleId }
    }

    static func blocked(_ evidence: [InstalledApplicationCacheEvidence], workspace: Workspace,
                        activity: any ApplicationUninstallChecking) throws -> [String: String] {
        guard !evidence.isEmpty else { return [:] }
        let facts: [String: ApplicationUninstallFacts]
        do { facts=try activity.facts(for: evidence.map(\.application)) }
        catch {
            if Task.isCancelled || (error as? ShouError)?.code == "cancelled" { throw ShouError("cancelled", "Application activity inspection stopped.") }
            return Dictionary(uniqueKeysWithValues: evidence.map { ($0.ruleId, "application_activity_unavailable") })
        }
        return evidence.reduce(into: [:]) { result, item in
            guard let fact=facts[item.application.id] else { result[item.ruleId]="application_activity_unavailable"; return }
            if fact.currentApplication { result[item.ruleId]="protected_content" }
            else if fact.currentUser != workspace.identity.owner { result[item.ruleId]="ownership_unverified" }
            else if fact.running { result[item.ruleId]="application_running" }
        }
    }

    static func revalidate(_ evidence: [InstalledApplicationCacheEvidence], workspace: Workspace, homeDirectory: URL,
                           platform: String, catalog: any ApplicationCatalogReading, staticRules: [CleanupRule],
                           inventoryRequired: Bool = true) throws {
        guard !evidence.isEmpty else { return }
        guard supports(workspace, homeDirectory: homeDirectory, platform: platform), Set(evidence.map(\.ruleId)).count == evidence.count else {
            throw ShouError("store_corrupt", "Installed application cache scope is invalid.")
        }
        let inventory: ApplicationCatalog?
        do { inventory=inventoryRequired ? try catalog.read(options: ApplicationCatalogOptions()) : nil }
        catch {
            if Task.isCancelled || (error as? ShouError)?.code == "cancelled" { throw ShouError("cancelled", "Application discovery stopped.") }
            throw ShouError("plan_stale", "Installed application ownership could not be verified; scan again.")
        }
        if let inventory, inventory.status != "complete" { throw ShouError("plan_stale", "Installed application ownership could not be verified; scan again.") }
        for item in evidence {
            _ = try rule(item, workspace: workspace)
            let identifier=item.application.bundleIdentifier!
            guard !covered(identifier, by: staticRules) else { throw ShouError("plan_stale", "A maintained rule already defines this cache scope; scan again.") }
            if let inventory {
                let owners=inventory.items.filter { $0.bundleIdentifier?.lowercased() == identifier.lowercased() }
                guard owners.count == 1, owners.first == item.application else {
                    throw ShouError("plan_stale", "Installed application ownership changed; scan again.")
                }
            }
            do {
                guard try catalog.application(at: item.application.path) == item.application else { throw ShouError("plan_stale", "Installed application identity changed; scan again.") }
            } catch {
                if Task.isCancelled || (error as? ShouError)?.code == "cancelled" { throw ShouError("cancelled", "Application discovery stopped.") }
                throw ShouError("plan_stale", "Installed application identity changed; scan again.")
            }
        }
    }
}
