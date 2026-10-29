import Foundation

/// Absence covers complete standard application sources and native registration,
/// with live-process checks. An unavailable source must never prove absence.
public protocol ApplicationAbsenceChecking: Sendable {
    func absentIdentifiers(in identifiers: Set<String>) throws -> Set<String>
}
public struct ApplicationOrphanReview: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let configurationDigest: String
    public let components: [UninstallComponent]
    public let limitations: [String]
    public let budget: ScanBudget
}
public struct ApplicationOrphanPlan: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let expiresAt: Date
    public let configurationDigest: String
    public let components: [UninstallComponent]
    public let includesUserData: Bool
    public let budget: ScanBudget
    public let action: String
    public var state: String
    public var executionId: String?
    public var digest: String
    public func calculatedDigest() throws -> String { var copy=self; copy.state="ready"; copy.executionId=nil; copy.digest=""; return try Digest.of(copy) }
}

extension ShouEngine {
    public func reviewApplicationOrphans(presence: any ApplicationAbsenceChecking, budget: ScanBudget = ScanBudget(), progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ApplicationOrphanReview {
        guard filesystem.platform == "macos" else { throw ShouError("capability_unavailable", "Application leftovers are available on macOS.") }
        try budget.validate()
        let config=try configuration()
        var identifiers=Set(try BuiltinCatalog.templates().flatMap { $0.applicationBundleIdentifiers ?? [] })
        // Previously verified bundle metadata extends maintained associations.
        for record in try store.records("application-reviews").sorted(by: { $0.modifiedAt > $1.modifiedAt }).prefix(500) {
            if let data=try store.read(record.collection, id: record.id), let review=try? Codec.decode(ApplicationUninstallReview.self, from: data), review.application.infoDigest != nil,
               let identifier=review.application.bundleIdentifier { identifiers.insert(identifier) }
        }
        identifiers=identifiers.filter { ReceiptOrigins.validIdentifier($0) && !$0.hasPrefix("com.apple.") && !$0.hasPrefix("dev.limecloud.shou") }
        let absent=try presence.absentIdentifiers(in: identifiers).intersection(identifiers)
        var components=[UninstallComponent](), remaining=budget.maxEntries
        let deadline=ContinuousClock.now.advanced(by: .seconds(budget.maxSeconds))
        for identifier in absent.sorted() {
            for kind in UninstallComponentKind.allCases where !kind.isApplicationRoot && kind != .groupContainer {
                if Task.isCancelled { throw ShouError("cancelled", "Leftover scan cancelled.") }
                guard let path=kind.associatedPath(bundleIdentifier: identifier, homeDirectory: homeDirectory) else { continue }
                if case .missing=filesystem.targetAvailability(path) { continue }
                progress(ScanProgress(stage: "scanning", entryCount: budget.maxEntries-remaining, currentPath: path))
                var reasons=[String](), manifest=[FileEntry](), origin: UninstallReceiptOrigin?, status="complete", bytes: Int64=0
                do {
                    let duration=ContinuousClock.now.duration(to: deadline).components
                    let seconds=Double(duration.seconds)+Double(duration.attoseconds)/1e18
                    guard remaining > 0, seconds >= 1 else { throw ShouError("resource_limit", "Leftover scan budget reached.") }
                    let parent=URL(fileURLWithPath: path).deletingLastPathComponent().path
                    let identity=try filesystem.rootIdentity(parent)
                    let tree=try filesystem.inspectTarget(path, budget: ScanBudget(maxEntries: remaining, maxSeconds: min(seconds,600), maxDepth: budget.maxDepth), cancelled: { Task.isCancelled })
                    remaining -= tree.entries.count; manifest=tree.entries
                    if !tree.complete { reasons.append("incomplete_scan") }
                    if manifest.contains(where: { !$0.hasSameOwner(as: identity) || $0.kind == "special" || $0.kind == "symlink" || ($0.kind == "file" && $0.links != 1) }) { reasons.append("protected_content") }
                    if manifest.first?.kind != (kind == .preferences ? "file" : "directory") { reasons.append("ownership_unverified") }
                    if kind == .container, try uninstallEvidence.containerIdentifier(at: path) != identifier { reasons.append("ownership_unverified") }
                    if uninstallExcluded(target: path, manifest: manifest, configuration: config, caseSensitive: tree.caseSensitive) { reasons.append("excluded") }
                    var measured=Set<String>()
                    bytes=manifest.filter { measured.insert($0.objectIdentityKey).inserted }.reduce(0) { $0 + max(0,$1.allocatedBytes) }
                    origin=UninstallReceiptOrigin(kind: kind, applicationPath: "", bundleIdentifier: identifier, parentPath: parent, parentIdentity: identity)
                } catch {
                    if Task.isCancelled { throw ShouError("cancelled", "Leftover scan cancelled.") }
                    reasons.append((error as? ShouError)?.code ?? "io_error"); status="unavailable"
                }
                components.append(UninstallComponent(id: Digest.sha256(Data(path.utf8)), kind: kind, path: path, status: status, origin: origin, manifest: manifest,
                    allocatedBytesEstimate: bytes, reasons: reasons, warnings: ["owner_absent_from_standard_sources_and_native_registration"]))
            }
        }
        let review=ApplicationOrphanReview(id: Codec.id("orphans"), createdAt: now(), configurationDigest: try Digest.of(config), components: components,
            limitations: ["maintained_or_previously_verified_bundle_identifiers_only", "custom_unregistered_installations_not_proven_absent", "shared_group_containers_not_removed", "personal_data_requires_separate_consent"], budget: budget)
        try store.write("orphan-reviews", id: review.id, data: Codec.encode(review)); return review
    }
    public func applicationOrphanPlan(_ id: String) throws -> ApplicationOrphanPlan {
        guard let data=try store.read("orphan-plans", id: id) else { throw ShouError("invalid_argument", "Unknown leftover plan.") }
        let plan=try Codec.decode(ApplicationOrphanPlan.self, from: data)
        guard plan.id == id, try plan.calculatedDigest() == plan.digest else { throw ShouError("store_corrupt", "Leftover plan is invalid.") }
        return plan
    }
    public func createApplicationOrphanPlan(reviewId: String, componentIds: [String], includeUserData: Bool = false, action: String = "permanent") throws -> ApplicationOrphanPlan {
        guard let data=try store.read("orphan-reviews", id: reviewId) else { throw ShouError("invalid_argument", "Unknown leftover review.") }
        let review=try Codec.decode(ApplicationOrphanReview.self, from: data)
        let selected=review.components.filter { componentIds.contains($0.id) }
        guard review.id == reviewId, now().timeIntervalSince(review.createdAt) < 900, review.configurationDigest == (try Digest.of(configuration())),
              !selected.isEmpty, Set(componentIds).count == componentIds.count, selected.count == componentIds.count,
              selected.allSatisfy({ $0.eligible && (!$0.requiresUserDataConsent || includeUserData) }), ["permanent","trash"].contains(action) else {
            throw ShouError("confirmation_required", "Review current eligible leftovers; personal data requires separate consent.")
        }
        var plan=ApplicationOrphanPlan(id: Codec.id("orphanplan"), createdAt: now(), expiresAt: now().addingTimeInterval(120), configurationDigest: review.configurationDigest,
            components: selected.sorted { $0.path < $1.path }, includesUserData: includeUserData, budget: review.budget, action: action, state: "ready", digest: "")
        plan.digest=try plan.calculatedDigest(); try store.write("orphan-plans", id: plan.id, data: Codec.encode(plan)); return plan
    }
    public func executeApplicationOrphans(planId: String, confirmedDigest: String, presence: any ApplicationAbsenceChecking, entryPoint: String,
                                          progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> ExecutionReceipt {
        let lease=try store.lock(); defer { lease.release() }
        var plan=try applicationOrphanPlan(planId)
        guard plan.state == "ready", plan.executionId == nil, plan.digest == confirmedDigest, plan.expiresAt > now(),
              plan.configurationDigest == (try Digest.of(configuration())), !plan.components.isEmpty else { throw ShouError("plan_stale", "Review leftovers again before cleaning.") }
        let first=plan.components[0]
        guard let origin=first.origin else { throw ShouError("store_corrupt", "Missing leftover origin.") }
        let workspace=Workspace(id: plan.id, rootRef: "application-orphans", path: origin.parentPath, identity: origin.parentIdentity, exclusions: [], addedAt: plan.createdAt)
        let items=plan.components.map { component in
            var item=ItemReceipt(id: component.id, originalPath: component.path, relativePath: URL(fileURLWithPath: component.path).lastPathComponent, trashPath: nil,
                manifest: component.manifest, state: "pending", allocatedBytesEstimate: component.allocatedBytesEstimate, error: nil)
            item.uninstallOrigin=component.origin; return item
        }
        let reviewedPlan=plan, executionConfiguration=try configuration()
        let validate: (Int) throws -> String? = { [self, plan=reviewedPlan] index in
            let component=plan.components[index]
            guard component.eligible, let origin=component.origin, origin.kind != .application, origin.kind != .groupContainer,
                  let identifier=origin.bundleIdentifier, ReceiptOrigins.validIdentifier(identifier),
                  component.path == origin.kind.associatedPath(bundleIdentifier: identifier, homeDirectory: homeDirectory),
                  (!component.requiresUserDataConsent || plan.includesUserData),
                  try Digest.of(executionConfiguration) == plan.configurationDigest,
                  try presence.absentIdentifiers(in: [identifier]).contains(identifier),
                  try filesystem.rootIdentity(origin.parentPath).sameObject(as: origin.parentIdentity) else { throw ShouError("ownership_unverified", "The owner or leftover scope changed. Scan again.") }
            try FileManifestVerification.beforeMutation(filesystem: filesystem, path: component.path, manifest: component.manifest, budget: plan.budget)
            let entries=component.manifest, sensitive=filesystem.caseSensitivePaths
            guard !entries.contains(where: { !$0.hasSameOwner(as: origin.parentIdentity) || $0.kind == "special" || $0.kind == "symlink" || ($0.kind == "file" && $0.links != 1) }),
                  !uninstallExcluded(target: component.path, manifest: entries, configuration: executionConfiguration, caseSensitive: sensitive) else { throw ShouError("plan_stale", "Leftover contents changed. Scan again.") }
            if origin.kind == .container, try uninstallEvidence.containerIdentifier(at: component.path) != origin.bundleIdentifier { throw ShouError("ownership_unverified", "Container ownership changed.") }
            return nil
        }
        let begin: (ExecutionReceipt) throws -> Void = { receipt in
            var executing=reviewedPlan
            executing.executionId=receipt.id; executing.state="executing"
            try self.store.write("orphan-plans", id: executing.id, data: Codec.encode(executing))
        }
        let receipt: ExecutionReceipt
        if plan.action == "permanent" {
            receipt=try PermanentExecution.run(planId: plan.id, workspace: workspace, items: items, entryPoint: entryPoint, store: store, filesystem: filesystem, now: now(), operation: "application_orphan_cleanup", progress: progress, didBegin: begin, validateItem: { index,_ in try validate(index) })
        } else {
            receipt=try TrashExecution.run(planId: plan.id, workspace: workspace, items: items, entryPoint: entryPoint, store: store, filesystem: filesystem, now: now(), operation: "application_orphan_cleanup", progress: progress, didBegin: begin, validateItem: { index in try validate(index) })
        }
        plan.executionId=receipt.id; plan.state=receipt.state
        try store.write("orphan-plans", id: plan.id, data: Codec.encode(plan)); return receipt
    }
}
