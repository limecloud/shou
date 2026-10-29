import Foundation

public enum UninstallComponentKind: String, Codable, CaseIterable, Sendable {
    case application, shortcut, caches, logs, preferences, applicationSupport, savedState, container, groupContainer, webKit, httpStorage
    public var isApplicationRoot: Bool { self == .application || self == .shortcut }
    public var requiresUserDataConsent: Bool { ![.application, .shortcut, .caches, .logs].contains(self) }
    public func associatedPath(bundleIdentifier: String, homeDirectory: URL) -> String? {
        let directory: String
        let suffix: String
        switch self {
        case .application, .shortcut: return nil
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

public struct ApplicationUninstallFacts: Codable, Sendable {
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
    public let bundleIdentifier: String?
    public let parentPath: String
    public let parentIdentity: FileEntry
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
    public var requiresAdministrator: Bool { kind.isApplicationRoot && warnings.contains("administrator_authorization_required") }
    public var requiresTrash: Bool {
        (requiresAdministrator && !warnings.contains("administrator_permanent_removal_available")) ||
            (kind == .application && warnings.contains("multiply_linked_content"))
    }
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
    public var requiresAdministrator: Bool { components.contains(where: \.requiresAdministrator) }
    public var requiresTrash: Bool { components.contains(where: \.requiresTrash) }
    public var keepsAssociatedData: Bool { requiresAdministrator || requiresTrash || components.contains { $0.kind == .shortcut } }
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
        if ["application_uninstall", "application_permanent_uninstall", "application_batch_uninstall", "application_batch_permanent_uninstall", "application_orphan_cleanup"].contains(receipt.operation ?? "") {
            guard let origin=item.uninstallOrigin,
                  (origin.bundleIdentifier.map(validIdentifier) == true || (origin.kind.isApplicationRoot && origin.bundleIdentifier == nil)),
                  !item.relativePath.contains("/"), !item.relativePath.contains("*"), !item.relativePath.contains("?"),
                  item.originalPath == origin.parentPath + "/" + item.relativePath,
                  origin.parentIdentity.kind == "directory", origin.parentIdentity.path == "." else {
                throw ShouError("store_corrupt", "Application receipt origin is invalid.")
            }
            if origin.kind == .shortcut {
                guard item.originalPath == origin.applicationPath, item.relativePath.lowercased().hasSuffix(".app"),
                      origin.bundleIdentifier == nil, item.manifest.count == 1, item.manifest.first?.path == ".", item.manifest.first?.kind == "symlink",
                      receipt.operation?.contains("permanent") == true else {
                    throw ShouError("store_corrupt", "Application shortcut receipt scope is invalid.")
                }
            } else if origin.kind == .application {
                guard item.originalPath == origin.applicationPath, item.relativePath.lowercased().hasSuffix(".app"), item.manifest.first?.kind == "directory" else {
                    throw ShouError("store_corrupt", "Application receipt does not identify an application bundle.")
                }
            } else if origin.kind == .groupContainer {
                let groupRoot=homeDirectory.appendingPathComponent("Library/Group Containers", isDirectory: true).path
                guard origin.bundleIdentifier != nil, origin.parentPath == groupRoot, item.originalPath == origin.parentPath + "/" + item.relativePath,
                      item.manifest.first?.kind == "directory" else {
                    throw ShouError("store_corrupt", "Application group container origin is outside its exact association.")
                }
            } else {
                guard let identifier=origin.bundleIdentifier,
                      item.originalPath == origin.kind.associatedPath(bundleIdentifier: identifier, homeDirectory: homeDirectory),
                      item.manifest.first?.kind == (origin.kind == .preferences ? "file" : "directory") else {
                    throw ShouError("store_corrupt", "Application receipt is outside its exact association.")
                }
            }
            return Origin(path: origin.parentPath, identity: origin.parentIdentity, applicationParent: origin.kind.isApplicationRoot)
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
        ApplicationDefinition.isValidBundleIdentifier(value)
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
    func prepareUninstallPlan(reviewId: String, componentIds: [String], includeUserData: Bool, action: String) throws -> ApplicationUninstallPlan {
        guard ["trash", "permanent"].contains(action) else { throw ShouError("invalid_argument", "Choose trash or permanent application removal.") }
        let review=try uninstallRecord(ApplicationUninstallReview.self, collection: "application-reviews", id: reviewId)
        guard !componentIds.isEmpty, Set(componentIds).count == componentIds.count else { throw ShouError("invalid_argument", "Select explicit application components.") }
        let selected=review.components.filter { componentIds.contains($0.id) }
        guard selected.count == componentIds.count, selected.filter({ $0.kind.isApplicationRoot }).count == 1,
              selected.allSatisfy({ $0.eligible && (!$0.kind.requiresUserDataConsent || includeUserData) }) else {
            throw ShouError("confirmation_required", "Select the application and eligible components; personal data requires separate consent.")
        }
        try validateAuthorizedApplicationSelection(selected, action: action)
        guard review.configurationDigest == (try Digest.of(configuration())), now().timeIntervalSince(review.checkedAt) <= 900 else {
            throw ShouError("plan_stale", "Application review expired or configuration changed; review again.")
        }
        var plan=ApplicationUninstallPlan(id: Codec.id("uninstall"), application: review.application, createdAt: now(), expiresAt: now().addingTimeInterval(900),
            configurationDigest: review.configurationDigest, components: selected.sorted { ($0.kind.isApplicationRoot ? 1 : 0, $0.path) < ($1.kind.isApplicationRoot ? 1 : 0, $1.path) },
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

    /// Single and batch freeze scope once, then validate and journal each item.
    func runUninstallPlans(_ plans: [ApplicationUninstallPlan], planId: String, action: String, entryPoint: String, operation: String,
                           progress: @Sendable (ExecutionProgress) -> Void,
                           didBegin: (ExecutionReceipt) throws -> Void) throws -> ExecutionReceipt {
        guard ["trash", "permanent"].contains(action), !plans.isEmpty else { throw ShouError("plan_stale", "Application removal mode or selection is invalid.") }
        try validateUninstallPlanOverlaps(plans)
        var components=[(plan: ApplicationUninstallPlan, component: UninstallComponent)]()
        for plan in plans {
            try plan.budget.validate()
            try validateAuthorizedApplicationSelection(plan.components, action: action)
            guard plan.executionId == nil, plan.effectiveAction == action, plan.expiresAt > now(),
                  try plan.configurationDigest == Digest.of(configuration()),
                  try plan.digest == plan.calculatedDigest(), !plan.components.isEmpty,
                  Set(plan.components.map(\.id)).count == plan.components.count,
                  plan.components.filter({ $0.kind.isApplicationRoot }).count == 1,
                  plan.components.last?.kind.isApplicationRoot == true,
                  plan.components.allSatisfy({ !$0.kind.requiresUserDataConsent || plan.includesUserData }) else {
                throw ShouError("plan_stale", "Application plan expired or has an invalid selection; preview again.")
            }
            let identifier=plan.application.bundleIdentifier.flatMap { ReceiptOrigins.validIdentifier($0) && plan.application.infoDigest != nil ? $0 : nil }
            guard plan.components.allSatisfy({ component in
                component.origin?.kind == component.kind && component.origin?.applicationPath == plan.application.path &&
                    component.origin?.bundleIdentifier == identifier
            }) else { throw ShouError("store_corrupt", "Application component origins do not match the reviewed application.") }
            components.append(contentsOf: plan.components.map { (plan, $0) })
        }
        guard action != "trash" || filesystem.supportsTrash else { throw ShouError("capability_unavailable", "Native Trash is required for application removal.") }
        let first=plans[0], appOrigin=try requireUninstallOrigin(first.components.first { $0.kind.isApplicationRoot })
        let workspace=Workspace(id: first.application.id, rootRef: "application-uninstall", path: appOrigin.parentPath,
            identity: appOrigin.parentIdentity, exclusions: [], addedAt: first.createdAt)
        let items=components.map { value in
            let component=value.component
            var item=ItemReceipt(id: component.id, originalPath: component.path, relativePath: URL(fileURLWithPath: component.path).lastPathComponent, trashPath: nil,
                manifest: component.manifest, state: "pending", allocatedBytesEstimate: component.allocatedBytesEstimate, error: nil)
            item.uninstallOrigin=component.origin
            return item
        }
        let scope=ExecutionReceipt(id: planId, planId: planId, workspace: workspace, createdAt: first.createdAt,
            entryPoint: entryPoint, state: "pending", items: items, volumeAvailableBefore: nil, volumeAvailableAfter: nil,
            operation: operation)
        for item in items { _ = try ReceiptOrigins.resolve(receipt: scope, item: item, homeDirectory: homeDirectory) }
        let validateItem: (Int) throws -> String? = { [self] index in
            let (plan, component)=components[index]
            guard component.eligible, try Digest.of(configuration()) == plan.configurationDigest,
                  try applicationCatalog.application(at: plan.application.path) == plan.application else {
                throw ShouError("plan_stale", "Application or configuration changed; preview again.")
            }
            if component.kind == .shortcut {
                let snapshot=try filesystem.applicationShortcut(component.path)
                let origin=try requireUninstallOrigin(component)
                guard action == "permanent", plan.components.count == 1, plan.application.identity.kind == "symlink",
                      component.manifest == [snapshot.identity], snapshot.parentIdentity.sameObject(as: origin.parentIdentity),
                      !uninstallExcluded(target: component.path, manifest: component.manifest, configuration: try configuration(), caseSensitive: filesystem.caseSensitivePaths),
                      !store.protectedPaths.contains(where: { Self.uninstallOverlaps(component.path, $0) }), !plan.application.isSystemApplication else {
                    throw ShouError("plan_stale", "The shortcut changed. Check this application again.")
                }
                return nil
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
                guard let identifier=origin.bundleIdentifier, try uninstallEvidence.groupContainerPaths(for: identifier).contains(component.path) else {
                    throw ShouError("ownership_unverified", "Group container ownership could not be verified.")
                }
            }
            if component.kind != .application {
                let currentInventory=try applicationCatalog.read(options: ApplicationCatalogOptions())
                guard !currentInventory.items.contains(where: { $0.path != plan.application.path && $0.bundleIdentifier == origin.bundleIdentifier }) else {
                    throw ShouError("ownership_unverified", "Another application may share this component.")
                }
            }
            guard !uninstallExcluded(target: component.path, manifest: component.manifest, configuration: try configuration(), caseSensitive: filesystem.caseSensitivePaths),
                  !store.protectedPaths.contains(where: { Self.uninstallOverlaps(component.path, $0) }),
                  !plan.application.isSystemApplication else { throw ShouError("protected_content", "This application component is protected or excluded.") }
            try FileManifestVerification.beforeMutation(filesystem: filesystem, path: component.path, manifest: component.manifest, budget: plan.budget)
            let authorizedBundle=component.kind == .application && component.requiresAdministrator &&
                (action == "trash" ? filesystem.supportsAuthorizedApplicationTrash : filesystem.supportsAuthorizedApplicationPermanentRemoval)
            let linkedBundle=action == "trash" && component.kind == .application
            guard !component.manifest.contains(where: { ($0.owner != facts.currentUser && !(authorizedBundle && $0.owner == 0)) || $0.kind == "special" || (!linkedBundle && $0.kind == "file" && $0.links != 1) }) else {
                throw ShouError("plan_stale", "Application component changed; preview again.")
            }
            return nil
        }
        if action == "permanent" {
            return try PermanentExecution.run(planId: planId, workspace: workspace, items: items, entryPoint: entryPoint,
                store: store, filesystem: filesystem, now: now(), operation: operation, progress: progress, didBegin: didBegin, validateItem: { index, _ in try validateItem(index) })
        }
        return try TrashExecution.run(planId: planId, workspace: workspace, items: items, entryPoint: entryPoint,
            store: store, filesystem: filesystem, now: now(), operation: operation, progress: progress, didBegin: didBegin, validateItem: validateItem)
    }

    private func analyzeApplication(path: String, budget: ScanBudget) throws -> ApplicationUninstallReview {
        try budget.validate()
        if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
        let deadline=ContinuousClock.now.advanced(by: .seconds(budget.maxSeconds))
        let app=try applicationCatalog.application(at: path), config=try configuration()
        if app.identity.kind == "symlink" { return try reviewApplicationShortcut(app, configuration: config, budget: budget) }
        let inventory=try applicationCatalog.read(options: ApplicationCatalogOptions())
        var common: [String]=[]
        if app.isSystemApplication { common.append("protected_application") }
        guard app.identity.kind == "directory" else { throw ShouError("ownership_unverified", "An application directory is required before uninstalling.") }
        let identifier=app.bundleIdentifier.flatMap { ReceiptOrigins.validIdentifier($0) && app.infoDigest != nil ? $0 : nil }
        let facts: ApplicationUninstallFacts?
        do {
            let checked=try uninstallEvidence.facts(for: app); facts=checked
            if checked.running { common.append("application_running") }
            if checked.currentApplication { common.append("protected_application") }
        } catch { facts=nil; common.append("application_activity_unavailable") }
        var remaining=budget.maxEntries, components: [UninstallComponent]=[]
        for kind in UninstallComponentKind.allCases where kind != .shortcut {
            if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
            if kind != .application && identifier == nil { continue }
            let targets: [String]
            if kind == .application { targets=[app.path] }
            else if kind == .groupContainer {
                let root=homeDirectory.appendingPathComponent("Library/Group Containers", isDirectory: true).path
                do {
                    targets=try uninstallEvidence.groupContainerPaths(for: identifier!).filter { path in
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
            } else { targets=[kind.associatedPath(bundleIdentifier: identifier!, homeDirectory: homeDirectory)!] }
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
                    if let facts {
                        let authorizedBundle=kind == .application && (filesystem.supportsAuthorizedApplicationTrash || filesystem.supportsAuthorizedApplicationPermanentRemoval)
                        if manifest.contains(where: { ($0.owner != facts.currentUser && !(authorizedBundle && $0.owner == 0)) || $0.kind == "special" || (kind != .application && $0.kind == "file" && $0.links != 1) }) {
                            reasons.append("protected_content")
                        } else if authorizedBundle && (manifest.contains(where: { $0.owner != facts.currentUser }) || filesystem.applicationNeedsAuthorization(target)) {
                            warnings.append("administrator_authorization_required")
                            if filesystem.supportsAuthorizedApplicationPermanentRemoval { warnings.append("administrator_permanent_removal_available") }
                        }
                    }
                    if kind == .application {
                        if identifier == nil { warnings.append("application_metadata_missing") }
                        if manifest.contains(where: { $0.kind == "file" && $0.links > 1 }) { warnings.append("multiply_linked_content") }
                    }
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
                        do { if try !uninstallEvidence.groupContainerPaths(for: identifier!).contains(target) { reasons.append("ownership_unverified") } }
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
    private func validateAuthorizedApplicationSelection(_ components: [UninstallComponent], action: String) throws {
        guard !components.contains(where: { $0.kind == .shortcut }) || (action == "permanent" && components.count == 1) else {
            throw ShouError("permission_denied", "A broken shortcut can only be removed on its own; its target and associated data are kept.")
        }
        guard !components.contains(where: \.requiresAdministrator) || (components.count == 1 &&
            (action == "trash" ? filesystem.supportsAuthorizedApplicationTrash : filesystem.supportsAuthorizedApplicationPermanentRemoval)) else {
            throw ShouError("permission_denied", "Applications requiring administrator access must be removed on their own. Associated app data is kept.")
        }
        guard !components.contains(where: \.requiresTrash) || (action == "trash" && components.count == 1) else {
            throw ShouError("permission_denied", "This application can only be moved to Trash on its own. Associated app data is kept.")
        }
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
    func uninstallExcluded(target: String, manifest: [FileEntry], configuration: Configuration, caseSensitive: Bool) -> Bool {
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
