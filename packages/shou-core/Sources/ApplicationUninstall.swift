import Foundation

public enum UninstallComponentKind: String, Codable, CaseIterable, Sendable {
    case application, caches, logs, preferences, applicationSupport, savedState, container, groupContainer, webKit, httpStorage
    public var requiresUserDataConsent: Bool { ![.application, .caches, .logs].contains(self) }
    public func associatedPath(bundleIdentifier: String, homeDirectory: URL) -> String? {
        let directory: String
        let suffix: String
        switch self {
        case .application: return nil
        case .caches: directory="Caches"; suffix=""
        case .logs: directory="Logs"; suffix=""
        case .preferences: directory="Preferences"; suffix=".plist"
        case .applicationSupport: directory="Application Support"; suffix=""
        case .savedState: directory="Saved Application State"; suffix=".savedState"
        case .container: directory="Containers"; suffix=""
        case .groupContainer: return nil
        case .webKit: directory="WebKit"; suffix=""
        case .httpStorage: directory="HTTPStorages"; suffix=""
        }
        return homeDirectory.appendingPathComponent("Library/" + directory + "/" + bundleIdentifier + suffix).path
    }
}

public struct ApplicationUninstallFacts: Sendable {
    public let currentUser: UInt32
    public let running: Bool
    public let currentApplication: Bool
    public init(currentUser: UInt32, running: Bool, currentApplication: Bool) {
        self.currentUser=currentUser; self.running=running; self.currentApplication=currentApplication
    }
}
public protocol ApplicationUninstallChecking: Sendable {
    func facts(for application: ApplicationDefinition) throws -> ApplicationUninstallFacts
    func facts(for applications: [ApplicationDefinition]) throws -> [String: ApplicationUninstallFacts]
    func containerIdentifier(at path: String) throws -> String
    /// Returns only shared containers whose native metadata identifies this exact application.
    /// The default keeps non-macOS and test adapters conservative.
    func groupContainerPaths(for bundleIdentifier: String) throws -> [String]
}
public extension ApplicationUninstallChecking {
    func groupContainerPaths(for bundleIdentifier: String) throws -> [String] { [] }
    func facts(for applications: [ApplicationDefinition]) throws -> [String: ApplicationUninstallFacts] {
        var result=[String: ApplicationUninstallFacts]()
        for application in applications {
            if Task.isCancelled { throw ShouError("cancelled", "Application summary stopped.") }
            result[application.id]=try facts(for: application)
        }
        return result
    }
}
public struct UnavailableApplicationUninstallEvidence: ApplicationUninstallChecking {
    public init() {}
    public func facts(for application: ApplicationDefinition) throws -> ApplicationUninstallFacts { throw ShouError("application_activity_unavailable", "Application activity could not be checked.") }
    public func containerIdentifier(at path: String) throws -> String { throw ShouError("ownership_unverified", "Container ownership could not be verified.") }
}

public struct UninstallReceiptOrigin: Codable, Sendable, Equatable {
    public let kind: UninstallComponentKind
    public let applicationPath: String
    public let bundleIdentifier: String
    public let parentPath: String
    public let parentIdentity: FileEntry
    func sameLocation(as other: UninstallReceiptOrigin) -> Bool {
        kind == other.kind && applicationPath == other.applicationPath && bundleIdentifier == other.bundleIdentifier &&
        parentPath == other.parentPath && parentIdentity.sameObject(as: other.parentIdentity)
    }
}
public struct UninstallComponent: Codable, Sendable, Identifiable {
    public let id: String
    public let kind: UninstallComponentKind
    public let path: String
    public let status: String
    public let origin: UninstallReceiptOrigin?
    public let manifest: [FileEntry]
    public let allocatedBytesEstimate: Int64
    public let reasons: [String]
    public let warnings: [String]
    public let eligible: Bool
    public let requiresUserDataConsent: Bool
    init(id: String, kind: UninstallComponentKind, path: String, status: String, origin: UninstallReceiptOrigin?, manifest: [FileEntry], allocatedBytesEstimate: Int64, reasons: [String], warnings: [String]) {
        self.id=id; self.kind=kind; self.path=path; self.status=status; self.origin=origin; self.manifest=manifest
        self.allocatedBytesEstimate=allocatedBytesEstimate; self.reasons=reasons; self.warnings=warnings
        self.eligible=status == "complete" && reasons.isEmpty && origin != nil && !manifest.isEmpty
        self.requiresUserDataConsent=kind.requiresUserDataConsent
    }
}
public struct ApplicationUninstallReview: Codable, Sendable, Identifiable {
    public let id: String
    public let application: ApplicationDefinition
    public let checkedAt: Date
    public let configurationDigest: String
    public let components: [UninstallComponent]
    public let limitations: [String]
    public let budget: ScanBudget
}
public struct ApplicationUninstallPlan: Codable, Sendable, Identifiable {
    public let id: String
    public let application: ApplicationDefinition
    public let createdAt: Date
    public let expiresAt: Date
    public let configurationDigest: String
    public let components: [UninstallComponent]
    public let includesUserData: Bool
    public let budget: ScanBudget
    public var state: String
    public var executionId: String?
    public var digest: String
    public var action: String? = nil
    public var effectiveAction: String { action ?? "trash" }
    public var allocatedBytesEstimate: Int64 { components.reduce(0) { $0 + $1.allocatedBytesEstimate } }
    public func calculatedDigest() throws -> String {
        var copy=self; copy.digest=""; copy.state="ready"; copy.executionId=nil
        return try Digest.of(copy)
    }
}

/// Application receipts carry an exact parent identity for every component.
/// Ordinary cleanup receipts retain the original registered-workspace contract.
enum ReceiptOrigins {
    struct Origin { let path: String; let identity: FileEntry; let applicationParent: Bool; var analysisRoot: Bool = false }
    static func resolve(receipt: ExecutionReceipt, item: ItemReceipt, homeDirectory: URL) throws -> Origin {
        if ["storage_removal", "storage_permanent_removal"].contains(receipt.operation ?? "") {
            guard StorageRemovalPolicy.validRelative(item.relativePath), item.uninstallOrigin == nil,
                  item.originalPath == StorageRemovalPolicy.absolute(root: receipt.workspace.path, relative: item.relativePath),
                  let root=item.manifest.first(where: { $0.path == "." }),
                  StorageRemovalPolicy.reason(root: receipt.workspace.path, path: item.relativePath, entry: root, home: homeDirectory.path, protectedPaths: []) == nil else {
                throw ShouError("store_corrupt", "Space analysis receipt origin is invalid.")
            }
            return Origin(path: receipt.workspace.path, identity: receipt.workspace.identity, applicationParent: false, analysisRoot: true)
        }
        try PathPattern.validate(item.relativePath)
        if ["application_uninstall", "application_permanent_uninstall", "application_batch_uninstall", "application_batch_permanent_uninstall"].contains(receipt.operation ?? "") {
            guard let origin=item.uninstallOrigin,
                  validIdentifier(origin.bundleIdentifier),
                  !item.relativePath.contains("/"), !item.relativePath.contains("*"), !item.relativePath.contains("?"),
                  item.originalPath == origin.parentPath + "/" + item.relativePath,
                  origin.parentIdentity.kind == "directory", origin.parentIdentity.path == "." else {
                throw ShouError("store_corrupt", "Application receipt origin is invalid.")
            }
            if origin.kind == .application {
                guard item.originalPath == origin.applicationPath, item.relativePath.lowercased().hasSuffix(".app"), item.manifest.first?.kind == "directory" else {
                    throw ShouError("store_corrupt", "Application receipt does not identify an application bundle.")
                }
            } else if origin.kind == .groupContainer {
                let groupRoot=homeDirectory.appendingPathComponent("Library/Group Containers", isDirectory: true).path
                guard origin.parentPath == groupRoot, item.originalPath == origin.parentPath + "/" + item.relativePath,
                      item.manifest.first?.kind == "directory" else {
                    throw ShouError("store_corrupt", "Application group container origin is outside its exact association.")
                }
            } else {
                guard item.originalPath == origin.kind.associatedPath(bundleIdentifier: origin.bundleIdentifier, homeDirectory: homeDirectory),
                      item.manifest.first?.kind == (origin.kind == .preferences ? "file" : "directory") else {
                    throw ShouError("store_corrupt", "Application receipt is outside its exact association.")
                }
            }
            return Origin(path: origin.parentPath, identity: origin.parentIdentity, applicationParent: origin.kind == .application)
        }
        guard receipt.operation == nil || receipt.operation == "permanent_cleanup", item.uninstallOrigin == nil, item.originalPath == receipt.workspace.path + "/" + item.relativePath else {
            throw ShouError("store_corrupt", "Receipt does not identify its original workspace item.")
        }
        return Origin(path: receipt.workspace.path, identity: receipt.workspace.identity, applicationParent: false)
    }
    static func identity(_ origin: Origin, filesystem: any PlatformFileSystem) throws -> FileEntry {
        if origin.analysisRoot { return try filesystem.analysisRootIdentity(origin.path) }
        return try origin.applicationParent ? filesystem.applicationParentIdentity(origin.path) : filesystem.rootIdentity(origin.path)
    }
    static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 255 && value.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
    }
}

extension ShouEngine {
    public func applications(options: ApplicationCatalogOptions = ApplicationCatalogOptions()) throws -> ApplicationCatalog {
        try options.validate()
        if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
        return try applicationCatalog.read(options: options)
    }

    public func reviewApplication(path: String, budget: ScanBudget = ScanBudget()) throws -> ApplicationUninstallReview {
        let review=try analyzeApplication(path: path, budget: budget)
        try store.write("application-reviews", id: review.id, data: Codec.encode(review))
        return review
    }
    public func uninstallPlan(_ id: String) throws -> ApplicationUninstallPlan {
        let plan=try uninstallRecord(ApplicationUninstallPlan.self, collection: "uninstall-plans", id: id)
        guard try plan.digest == plan.calculatedDigest() else { throw ShouError("store_corrupt", "Application plan digest is invalid.") }
        return plan
    }
    public func createUninstallPlan(reviewId: String, componentIds: [String], includeUserData: Bool = false, action: String = "trash") throws -> ApplicationUninstallPlan {
        let lease=try store.lock(); defer { lease.release() }
        let plan=try prepareUninstallPlan(reviewId: reviewId, componentIds: componentIds, includeUserData: includeUserData, action: action)
        try store.write("uninstall-plans", id: plan.id, data: Codec.encode(plan))
        return plan
    }
    func prepareUninstallPlan(reviewId: String, componentIds: [String], includeUserData: Bool, action: String,
                              inventory: ApplicationCatalog? = nil) throws -> ApplicationUninstallPlan {
        guard ["trash", "permanent"].contains(action) else { throw ShouError("invalid_argument", "Choose trash or permanent application removal.") }
        let review=try uninstallRecord(ApplicationUninstallReview.self, collection: "application-reviews", id: reviewId)
        guard !componentIds.isEmpty, Set(componentIds).count == componentIds.count else { throw ShouError("invalid_argument", "Select explicit application components.") }
        let selected=review.components.filter { componentIds.contains($0.id) }
        guard selected.count == componentIds.count, selected.filter({ $0.kind == .application }).count == 1,
              selected.allSatisfy({ $0.eligible && (!$0.kind.requiresUserDataConsent || includeUserData) }) else {
            throw ShouError("confirmation_required", "Select the application and eligible components; personal data requires separate consent.")
        }
        let current=try analyzeApplication(path: review.application.path, budget: review.budget, inventory: inventory)
        try validateUninstallSelection(application: review.application, digest: review.configurationDigest, selected: selected, current: current)
        var plan=ApplicationUninstallPlan(id: Codec.id("uninstall"), application: current.application, createdAt: now(), expiresAt: now().addingTimeInterval(900),
            configurationDigest: current.configurationDigest, components: selected.sorted { ($0.kind == .application ? 1 : 0, $0.path) < ($1.kind == .application ? 1 : 0, $1.path) },
            includesUserData: includeUserData, budget: review.budget, state: "ready", executionId: nil, digest: "")
        // Omit the legacy default so older persisted Trash-plan digests remain valid.
        if action != "trash" { plan.action=action }
        plan.digest=try plan.calculatedDigest()
        return plan
    }
    public func executeUninstall(planId: String, confirmedDigest: String, entryPoint: String, progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> ExecutionReceipt {
        let lease=try store.lock(); defer { lease.release() }
        var plan=try uninstallPlan(planId)
        guard plan.executionId == nil else { throw ShouError("already_executed", "This plan already has an execution record.") }
        guard plan.digest == confirmedDigest else { throw ShouError("confirmation_required", "Confirmation does not match the current plan.") }
        let receipt=try runUninstallPlans([plan], planId: plan.id, action: plan.effectiveAction, entryPoint: entryPoint,
            operation: plan.effectiveAction == "permanent" ? "application_permanent_uninstall" : "application_uninstall", progress: progress,
            didBegin: { receipt in
                plan.executionId=receipt.id; plan.state="executing"
                try store.write("uninstall-plans", id: plan.id, data: Codec.encode(plan))
            })
        plan.state=receipt.state
        try store.write("uninstall-plans", id: plan.id, data: Codec.encode(plan))
        return receipt
    }

    /// Single and batch use the same complete preflight and per-item journal gate.
    func runUninstallPlans(_ plans: [ApplicationUninstallPlan], planId: String, action: String, entryPoint: String, operation: String,
                           progress: @Sendable (ExecutionProgress) -> Void,
                           didBegin: (ExecutionReceipt) throws -> Void) throws -> ExecutionReceipt {
        guard ["trash", "permanent"].contains(action), !plans.isEmpty else { throw ShouError("plan_stale", "Application removal mode or selection is invalid.") }
        try validateUninstallPlanOverlaps(plans)
        let inventory=try applicationCatalog.read(options: ApplicationCatalogOptions())
        var components=[(plan: ApplicationUninstallPlan, component: UninstallComponent)]()
        for plan in plans {
            try plan.budget.validate()
            guard plan.executionId == nil, plan.effectiveAction == action, plan.expiresAt > now(),
                  try plan.digest == plan.calculatedDigest(), !plan.components.isEmpty,
                  Set(plan.components.map(\.id)).count == plan.components.count,
                  plan.components.filter({ $0.kind == .application }).count == 1,
                  plan.components.last?.kind == .application,
                  plan.components.allSatisfy({ !$0.kind.requiresUserDataConsent || plan.includesUserData }) else {
                throw ShouError("plan_stale", "Application plan expired or has an invalid selection; preview again.")
            }
            progress(ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: plans.reduce(0) { $0 + $1.components.count }, path: plan.application.path))
            let current=try analyzeApplication(path: plan.application.path, budget: plan.budget, inventory: inventory)
            try validateUninstallSelection(application: plan.application, digest: plan.configurationDigest, selected: plan.components, current: current)
            components.append(contentsOf: plan.components.map { (plan, $0) })
        }
        guard action != "trash" || filesystem.supportsTrash else { throw ShouError("capability_unavailable", "Native Trash is required for application removal.") }
        let first=plans[0], appOrigin=try requireUninstallOrigin(first.components.first { $0.kind == .application })
        let workspace=Workspace(id: first.application.id, rootRef: "application-uninstall", path: appOrigin.parentPath,
            identity: appOrigin.parentIdentity, exclusions: [], addedAt: first.createdAt)
        let items=components.map { value in
            let component=value.component
            var item=ItemReceipt(id: component.id, originalPath: component.path, relativePath: URL(fileURLWithPath: component.path).lastPathComponent, trashPath: nil,
                manifest: component.manifest, state: "pending", allocatedBytesEstimate: component.allocatedBytesEstimate, error: nil)
            item.uninstallOrigin=component.origin
            return item
        }
        let validateItem: (Int) throws -> String? = { [self] index in
            let (plan, component)=components[index]
            guard try Digest.of(configuration()) == plan.configurationDigest,
                  try applicationCatalog.application(at: plan.application.path) == plan.application else {
                throw ShouError("plan_stale", "Application or configuration changed; preview again.")
            }
            let facts=try uninstallEvidence.facts(for: plan.application)
            guard !facts.running, !facts.currentApplication else { throw ShouError("application_running", "Quit the application and its helpers before uninstalling.") }
            let origin=try requireUninstallOrigin(component)
            let identity=try component.kind == .application ? filesystem.applicationParentIdentity(origin.parentPath) : filesystem.rootIdentity(origin.parentPath)
            guard identity.sameObject(as: origin.parentIdentity) else { throw ShouError("access_expired", "Component parent changed; preview again.") }
            if component.kind == .container {
                guard try uninstallEvidence.containerIdentifier(at: component.path) == origin.bundleIdentifier else {
                    throw ShouError("ownership_unverified", "Container ownership could not be verified.")
                }
            }
            if component.kind == .groupContainer {
                guard try uninstallEvidence.groupContainerPaths(for: origin.bundleIdentifier).contains(component.path) else {
                    throw ShouError("ownership_unverified", "Group container ownership could not be verified.")
                }
            }
            if component.kind != .application {
                let currentInventory=try applicationCatalog.read(options: ApplicationCatalogOptions())
                guard !currentInventory.items.contains(where: { $0.path != plan.application.path && $0.bundleIdentifier == origin.bundleIdentifier }) else {
                    throw ShouError("ownership_unverified", "Another application may share this component.")
                }
            }
            let tree=try filesystem.inspectTarget(component.path, budget: plan.budget, cancelled: { Task.isCancelled })
            guard tree.complete, tree.entries == component.manifest,
                  !tree.entries.contains(where: { $0.owner != facts.currentUser || $0.kind == "special" || ($0.kind == "file" && $0.links != 1) }) else {
                throw ShouError("plan_stale", "Application component changed; preview again.")
            }
            return nil
        }
        if action == "permanent" {
            return try PermanentExecution.run(planId: planId, workspace: workspace, items: items, entryPoint: entryPoint,
                store: store, filesystem: filesystem, now: now(), operation: operation, progress: progress, didBegin: didBegin, validateItem: validateItem)
        }
        return try TrashExecution.run(planId: planId, workspace: workspace, items: items, entryPoint: entryPoint,
            store: store, filesystem: filesystem, now: now(), operation: operation, progress: progress, didBegin: didBegin, validateItem: validateItem)
    }

    private func analyzeApplication(path: String, budget: ScanBudget, inventory savedInventory: ApplicationCatalog? = nil) throws -> ApplicationUninstallReview {
        try budget.validate()
        if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
        let deadline=ContinuousClock.now.advanced(by: .seconds(budget.maxSeconds))
        let app=try applicationCatalog.application(at: path), config=try configuration()
        let inventory=try savedInventory ?? applicationCatalog.read(options: ApplicationCatalogOptions())
        var common: [String]=[]
        if app.source.systemOwned || app.bundleIdentifier?.hasPrefix("com.apple.") == true { common.append("protected_application") }
        guard let identifier=app.bundleIdentifier, ReceiptOrigins.validIdentifier(identifier), app.infoDigest != nil else {
            throw ShouError("ownership_unverified", "A valid application identifier and metadata are required before uninstalling.")
        }
        let facts: ApplicationUninstallFacts?
        do {
            let checked=try uninstallEvidence.facts(for: app); facts=checked
            if checked.running { common.append("application_running") }
            if checked.currentApplication { common.append("protected_application") }
        } catch { facts=nil; common.append("application_activity_unavailable") }
        var remaining=budget.maxEntries, components: [UninstallComponent]=[]
        for kind in UninstallComponentKind.allCases {
            if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
            let targets: [String]
            if kind == .application { targets=[app.path] }
            else if kind == .groupContainer {
                let root=homeDirectory.appendingPathComponent("Library/Group Containers", isDirectory: true).path
                do {
                    targets=try uninstallEvidence.groupContainerPaths(for: identifier).filter { path in
                        guard path.hasPrefix(root + "/") else { return false }
                        let relative=String(path.dropFirst(root.count + 1))
                        return !relative.isEmpty && !relative.contains("/") && !relative.contains("..") &&
                            URL(fileURLWithPath: path).standardized.path == path
                    }.sorted()
                }
                catch let error as ShouError {
                    if error.code == "cancelled" { throw error }
                    warningsForGroupCoverage(&common, error: error)
                    continue
                }
            } else { targets=[kind.associatedPath(bundleIdentifier: identifier, homeDirectory: homeDirectory)!] }
            for target in targets {
                if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
            let id=Digest.sha256(Data((kind.rawValue + "\0" + target).utf8))
            var reasons=common, warnings: [String]=[], status="complete", manifest: [FileEntry]=[], origin: UninstallReceiptOrigin?
            switch filesystem.targetAvailability(target) {
            case .missing: status="missing"
            case .unavailable: status="unavailable"; reasons.append("permission_or_type_unavailable")
            case .available:
                do {
                    let duration=ContinuousClock.now.duration(to: deadline).components
                    let seconds=Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                    guard seconds >= 1, remaining > 0 else { throw ShouError("resource_limit", "Application review budget was exhausted.") }
                    let tree=try filesystem.inspectTarget(target, budget: ScanBudget(maxEntries: remaining, maxSeconds: min(seconds, budget.maxSeconds), maxDepth: budget.maxDepth), cancelled: { Task.isCancelled })
                    manifest=tree.entries; remaining=max(0, remaining - manifest.count)
                    if !tree.complete { status="partial"; reasons.append("incomplete_manifest") }
                    let expectedKind=kind == .preferences ? "file" : "directory"
                    if manifest.first?.kind != expectedKind { reasons.append("unsupported_component_type") }
                    if let facts, manifest.contains(where: { $0.owner != facts.currentUser || $0.kind == "special" || ($0.kind == "file" && $0.links != 1) }) { reasons.append("protected_content") }
                    let parent=URL(fileURLWithPath: target).deletingLastPathComponent().path
                    let identity=try kind == .application ? filesystem.applicationParentIdentity(parent) : filesystem.rootIdentity(parent)
                    origin=UninstallReceiptOrigin(kind: kind, applicationPath: app.path, bundleIdentifier: identifier, parentPath: parent, parentIdentity: identity)
                    if kind != .application {
                        if inventory.status != "complete" { warnings.append("ownership_coverage_incomplete") }
                        if inventory.items.contains(where: { $0.path != app.path && $0.bundleIdentifier == identifier }) { reasons.append("shared_component") }
                    }
                    if kind == .container {
                        do { if try uninstallEvidence.containerIdentifier(at: target) != identifier { reasons.append("ownership_unverified") } }
                        catch { reasons.append("ownership_unverified") }
                    }
                    if kind == .groupContainer {
                        do { if try !uninstallEvidence.groupContainerPaths(for: identifier).contains(target) { reasons.append("ownership_unverified") } }
                        catch { reasons.append("ownership_unverified") }
                    }
                    if uninstallExcluded(target: target, manifest: manifest, configuration: config, caseSensitive: tree.caseSensitive) { reasons.append("excluded_descendant") }
                    if store.protectedPaths.contains(where: { Self.uninstallOverlaps(target, $0) }) { reasons.append("protected_content") }
                } catch let error as ShouError {
                    if error.code == "cancelled" { throw error }
                    status="unavailable"; reasons.append(error.code)
                }
            }
            var seen=Set<String>(), allocated: Int64=0
            for entry in manifest where entry.kind != "symlink" && seen.insert("\(entry.device):\(entry.inode)").inserted { allocated += max(0, entry.allocatedBytes) }
            components.append(UninstallComponent(id: id, kind: kind, path: target, status: status, origin: origin, manifest: manifest, allocatedBytesEstimate: allocated, reasons: Array(Set(reasons)).sorted(), warnings: warnings))
            }
        }
        guard try applicationCatalog.application(at: path) == app else { throw ShouError("application_changed", "Application changed while reading its metadata.") }
        return ApplicationUninstallReview(id: Codec.id("appreview"), application: app, checkedAt: now(), configurationDigest: try Digest.of(config), components: components,
            limitations: ["exact_bundle_identifier_associations_only", "unverified_group_containers_not_removed", "package_receipts_not_removed", "embedded_helpers_not_unregistered", "custom_locations_not_searched", "other_accounts_not_searched"], budget: budget)
    }
    private func warningsForGroupCoverage(_ common: inout [String], error: ShouError) {
        if error.code != "resource_limit" && error.code != "permission_denied" && error.code != "io_error" {
            common.append("group_container_coverage_unavailable")
        }
    }
    private func validateUninstallSelection(application: ApplicationDefinition, digest: String, selected: [UninstallComponent], current: ApplicationUninstallReview) throws {
        // Activity failures are retryable inspection failures, not evidence that
        // the selected files changed. Preserve their cause for both entry points.
        if current.application == application, current.configurationDigest == digest {
            for saved in selected {
                guard let value=current.components.first(where: { $0.id == saved.id }) else { continue }
                if value.reasons.contains("application_activity_unavailable") {
                    throw ShouError("application_activity_unavailable", "Application processes and helpers could not be verified.", details: ["path": value.path])
                }
                if value.reasons.contains("application_running") {
                    throw ShouError("application_running", "Quit the application and its helpers before uninstalling.", details: ["path": value.path])
                }
            }
        }
        guard current.application == application, current.configurationDigest == digest,
              selected.allSatisfy({ saved in current.components.contains { value in
                  value.id == saved.id && value.path == saved.path && value.kind == saved.kind && value.eligible && saved.eligible &&
                  value.requiresUserDataConsent == saved.requiresUserDataConsent && value.warnings == saved.warnings &&
                  value.manifest == saved.manifest && value.origin.flatMap { fresh in saved.origin.map { fresh.sameLocation(as: $0) } } == true
              } }) else { throw ShouError("plan_stale", "Application, ownership, configuration or component contents changed; preview again.") }
    }
    private func requireUninstallOrigin(_ component: UninstallComponent?) throws -> UninstallReceiptOrigin {
        guard let origin=component?.origin else { throw ShouError("store_corrupt", "Application component origin is missing.") }
        return origin
    }
    func uninstallRecord<T: Decodable>(_ type: T.Type, collection: String, id: String) throws -> T {
        guard let bytes=try store.read(collection, id: id) else { throw ShouError("invalid_argument", "Record does not exist.") }
        do { return try Codec.decode(type, from: bytes) }
        catch { throw ShouError("store_corrupt", "Stored application record is invalid.") }
    }
    private static func uninstallOverlaps(_ a: String, _ b: String) -> Bool {
        let a=a.lowercased(), b=b.lowercased()
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
    private func uninstallExcluded(target: String, manifest: [FileEntry], configuration: Configuration, caseSensitive: Bool) -> Bool {
        let protectedNames: Set<String>=[".ssh", ".gnupg", ".aws", ".azure", ".kube", ".shou", "keychains"]
        for entry in manifest {
            let path=entry.path == "." ? target : target + "/" + entry.path
            if entry.path.split(separator: "/").contains(where: { protectedNames.contains($0.lowercased()) }) { return true }
            let global=configuration.globalExclusions ?? []
            let relative=path.hasPrefix(homeDirectory.path + "/") ? String(path.dropFirst(homeDirectory.path.count + 1)) : String(path.dropFirst())
            if uninstallMatches(global, relative, caseSensitive: caseSensitive) { return true }
            for workspace in configuration.workspaces {
                if path == workspace.path || path.hasPrefix(workspace.path + "/") {
                    let relative=path == workspace.path ? "." : String(path.dropFirst(workspace.path.count + 1))
                    if uninstallMatches(workspace.exclusions + global, relative, caseSensitive: caseSensitive) { return true }
                }
            }
        }
        return false
    }
    private func uninstallMatches(_ patterns: [String], _ relative: String, caseSensitive: Bool) -> Bool {
        let parts=relative.split(separator: "/")
        return (1...max(1, parts.count)).contains { count in patterns.contains { PathPattern.matches($0, parts.prefix(count).joined(separator: "/"), caseSensitive: caseSensitive) } }
    }
}
