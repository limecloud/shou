import Foundation

public struct ApplicationClosePlan: Codable, Sendable, Identifiable {
    public let id: String
    public let applications: [ApplicationDefinition]
    public let createdAt: Date
    public let expiresAt: Date
    public var digest: String
    public func calculatedDigest() throws -> String { var copy=self; copy.digest=""; return try Digest.of(copy) }
}
public struct ApplicationCloseResult: Codable, Sendable, Identifiable {
    public var id: String { applicationId }
    public let applicationId: String
    public let name: String
    public let state: String
    public let error: String?
    public init(applicationId: String, name: String, state: String, error: String? = nil) {
        self.applicationId=applicationId; self.name=name; self.state=state; self.error=error
    }
}
public protocol ApplicationClosing: Sendable {
    func requestClose(_ application: ApplicationDefinition) async throws
}

extension ShouEngine {
    public func cleanupApplicationClosePlan(scanIds: [String]) throws -> ApplicationClosePlan {
        guard !scanIds.isEmpty, scanIds.count <= 200 else { throw ShouError("invalid_argument", "Select current cleanup scans.") }
        let snapshots=try scanIds.map { try scanSnapshot($0) }
        let configDigest=try Digest.of(configuration())
        guard snapshots.allSatisfy({ $0.configurationDigest == configDigest && !$0.previewOnly }) else { throw ShouError("plan_stale", "Scan again before closing applications.") }
        let blockedRuleIDs=Set(snapshots.flatMap(\.candidates).filter { $0.reasons.contains("application_running") }.flatMap(\.ruleIds))
        let staticIDs=try BuiltinCatalog.templates().filter { blockedRuleIDs.contains($0.id) }.flatMap { $0.applicationBundleIdentifiers ?? [] }
        let dynamicIDs=snapshots.flatMap { $0.installedApplicationCaches ?? [] }.filter { blockedRuleIDs.contains($0.ruleId) }.compactMap { $0.application.bundleIdentifier }
        let identifiers=Set(staticIDs + dynamicIDs)
        let inventory=try applicationCatalog.read(options: .init())
        let grouped=Dictionary(grouping: inventory.items, by: { $0.bundleIdentifier ?? "" })
        let applications=identifiers.sorted().compactMap { identifier -> ApplicationDefinition? in
            guard let matches=grouped[identifier], matches.count == 1 else { return nil }
            return matches[0]
        }
        return try applicationClosePlan(applications: applications)
    }

    public func applicationClosePlan(applications: [ApplicationDefinition]) throws -> ApplicationClosePlan {
        guard applications.count <= 100, Set(applications.map(\.id)).count == applications.count else { throw ShouError("invalid_argument", "Select distinct applications.") }
        for app in applications {
            let current=try applicationCatalog.application(at: app.path)
            let facts=try uninstallEvidence.facts(for: current)
            guard current == app, !app.source.systemOwned, app.bundleIdentifier?.hasPrefix("com.apple.") == false,
                  app.bundleIdentifier?.hasPrefix("dev.limecloud.shou") == false, !facts.currentApplication else {
                throw ShouError("protected_content", "This application cannot be closed by cleanup.")
            }
        }
        var plan=ApplicationClosePlan(id: Codec.id("close"), applications: applications, createdAt: now(), expiresAt: now().addingTimeInterval(120), digest: "")
        plan.digest=try plan.calculatedDigest()
        try store.write("application-close-plans", id: plan.id, data: Codec.encode(plan))
        return plan
    }

    public func applicationClosePlan(_ id: String) throws -> ApplicationClosePlan {
        guard let data=try store.read("application-close-plans", id: id) else { throw ShouError("invalid_argument", "Unknown application-close plan.") }
        let plan=try Codec.decode(ApplicationClosePlan.self, from: data)
        guard plan.id == id, try plan.calculatedDigest() == plan.digest else { throw ShouError("store_corrupt", "Application-close plan is invalid.") }
        return plan
    }

    public func closeApplications(planId: String, confirmedDigest: String, controller: any ApplicationClosing, timeoutSeconds: Double = 10) async throws -> [ApplicationCloseResult] {
        let plan=try applicationClosePlan(planId)
        guard plan.expiresAt > now(), plan.digest == confirmedDigest, timeoutSeconds.isFinite, (0...30).contains(timeoutSeconds) else { throw ShouError("confirmation_required", "Application-close confirmation expired or changed.") }
        var results=[ApplicationCloseResult]()
        for app in plan.applications {
            if Task.isCancelled { throw ShouError("cancelled", "Application close cancelled.") }
            do {
                guard try applicationCatalog.application(at: app.path) == app else { throw ShouError("plan_stale", "Application identity changed.") }
                let facts=try uninstallEvidence.facts(for: app)
                guard !facts.currentApplication else { throw ShouError("protected_content", "Shou cannot close itself.") }
                if facts.running { try await controller.requestClose(app) }
                let deadline=ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
                var running=try uninstallEvidence.facts(for: app).running
                while running && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                    running=try uninstallEvidence.facts(for: app).running
                }
                results.append(.init(applicationId: app.id, name: app.name, state: running ? "still_running" : "closed"))
            } catch {
                if Task.isCancelled { throw ShouError("cancelled", "Application close cancelled.") }
                results.append(.init(applicationId: app.id, name: app.name, state: "failed", error: error.localizedDescription))
            }
        }
        return results
    }
}
