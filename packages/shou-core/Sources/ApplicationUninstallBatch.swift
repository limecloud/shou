import Foundation

public struct ApplicationUninstallSelection: Codable, Sendable {
    public let reviewId: String
    public let componentIds: [String]
    public let includeUserData: Bool
    public init(reviewId: String, componentIds: [String], includeUserData: Bool = false) {
        self.reviewId=reviewId; self.componentIds=componentIds; self.includeUserData=includeUserData
    }
    enum CodingKeys: String, CodingKey { case reviewId, componentIds, includeUserData }
    public init(from decoder: any Decoder) throws {
        let values=try decoder.container(keyedBy: CodingKeys.self)
        reviewId=try values.decode(String.self, forKey: .reviewId)
        componentIds=try values.decode([String].self, forKey: .componentIds)
        includeUserData=try values.decodeIfPresent(Bool.self, forKey: .includeUserData) ?? false
    }
}

public struct ApplicationUninstallBatchPlan: Codable, Sendable, Identifiable {
    public let id: String
    public let plans: [ApplicationUninstallPlan]
    public let action: String
    public let createdAt: Date
    public let expiresAt: Date
    public var state: String
    public var executionId: String?
    public var digest: String
    public var allocatedBytesEstimate: Int64 { plans.reduce(0) { $0 + $1.allocatedBytesEstimate } }
    public func calculatedDigest() throws -> String {
        var copy=self; copy.digest=""; copy.state="ready"; copy.executionId=nil
        return try Digest.of(copy)
    }
}

extension ShouEngine {
    public func createUninstallBatchPlan(selections: [ApplicationUninstallSelection], action: String = "permanent") throws -> ApplicationUninstallBatchPlan {
        guard !selections.isEmpty, selections.count <= 100,
              Set(selections.map(\.reviewId)).count == selections.count,
              ["trash", "permanent"].contains(action) else {
            throw ShouError("invalid_argument", "Select 1–100 distinct application reviews and a supported removal mode.")
        }
        let lease=try store.lock(); defer { lease.release() }
        var plans=[ApplicationUninstallPlan]()
        for selection in selections {
            if Task.isCancelled { throw ShouError("cancelled", "Application batch planning stopped.") }
            plans.append(try prepareUninstallPlan(reviewId: selection.reviewId, componentIds: selection.componentIds,
                includeUserData: selection.includeUserData, action: action))
        }
        try validateUninstallPlanOverlaps(plans)
        var plan=ApplicationUninstallBatchPlan(id: Codec.id("uninstallbatch"), plans: plans.sorted { $0.application.path < $1.application.path },
            action: action, createdAt: now(), expiresAt: plans.map(\.expiresAt).min()!, state: "ready", executionId: nil, digest: "")
        plan.digest=try plan.calculatedDigest()
        try store.write("uninstall-batch-plans", id: plan.id, data: Codec.encode(plan))
        return plan
    }
    public func uninstallBatchPlan(_ id: String) throws -> ApplicationUninstallBatchPlan {
        let plan=try uninstallRecord(ApplicationUninstallBatchPlan.self, collection: "uninstall-batch-plans", id: id)
        guard try plan.digest == plan.calculatedDigest(), (1...100).contains(plan.plans.count),
              ["trash", "permanent"].contains(plan.action) else { throw ShouError("store_corrupt", "Application batch plan is invalid.") }
        try validateUninstallPlanOverlaps(plan.plans)
        return plan
    }
    public func executeUninstallBatch(planId: String, confirmedDigest: String, entryPoint: String,
                                      progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> ExecutionReceipt {
        let lease=try store.lock(); defer { lease.release() }
        var plan=try uninstallBatchPlan(planId)
        guard plan.executionId == nil else { throw ShouError("already_executed", "This batch already has an execution record.") }
        guard plan.digest == confirmedDigest else { throw ShouError("confirmation_required", "Confirmation does not match the application batch.") }
        guard plan.expiresAt > now(), plan.plans.allSatisfy({ $0.effectiveAction == plan.action }) else {
            throw ShouError("plan_stale", "Application batch expired or changed; review again.")
        }
        let operation=plan.action == "permanent" ? "application_batch_permanent_uninstall" : "application_batch_uninstall"
        let receipt=try runUninstallPlans(plan.plans, planId: plan.id, action: plan.action, entryPoint: entryPoint,
            operation: operation, progress: progress, didBegin: { receipt in
                plan.executionId=receipt.id; plan.state="executing"
                try store.write("uninstall-batch-plans", id: plan.id, data: Codec.encode(plan))
            })
        plan.state=receipt.state
        try store.write("uninstall-batch-plans", id: plan.id, data: Codec.encode(plan))
        return receipt
    }
    /// Reject duplicate apps and every equal/ancestor component boundary before
    /// any batch receipt or mutation exists, including case-insensitive aliases.
    func validateUninstallPlanOverlaps(_ plans: [ApplicationUninstallPlan]) throws {
        guard Set(plans.map { $0.application.path.lowercased() }).count == plans.count else {
            throw ShouError("invalid_argument", "The same application cannot appear twice in a batch.")
        }
        let paths=plans.flatMap(\.components).map { $0.path.lowercased() }.sorted()
        var ancestors=Set<String>()
        for path in paths {
            var current=path
            while true {
                if ancestors.contains(current) { throw ShouError("invalid_argument", "Selected applications contain overlapping component paths.", details: ["path": path]) }
                guard let slash=current.lastIndex(of: "/"), slash != current.startIndex else { break }
                current=String(current[..<slash])
            }
            ancestors.insert(path)
        }
    }
}
