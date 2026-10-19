import Foundation

public actor ShouEngine {
    private let store: any RecordStore
    let filesystem: any PlatformFileSystem
    let homeDirectory: URL
    private let applicationActivity: any ApplicationActivityChecking
    private let artifactEvidence: any ArtifactEvidenceChecking
    private let now: @Sendable () -> Date
    public init(store: any RecordStore, filesystem: any PlatformFileSystem, applicationActivity: any ApplicationActivityChecking = UnavailableApplicationActivity(), artifactEvidence: any ArtifactEvidenceChecking = UnavailableArtifactEvidence(), homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store=store; self.filesystem=filesystem; self.applicationActivity=applicationActivity; self.artifactEvidence=artifactEvidence; self.homeDirectory=homeDirectory; self.now=now
    }
    public func configuration() throws -> Configuration {
        guard let data = try store.read("configuration", id: "current") else { return Configuration() }
        do {
            let config=try Codec.decode(Configuration.self, from: data)
            guard config.version == 1 else { throw ShouError("store_corrupt", "Unsupported configuration version.") }
            for record in config.rules {
                guard try Digest.of(record.rule) == record.digest else { throw ShouError("store_corrupt", "Stored rule digest verification failed.") }
                _ = try CleanupRule.parse(Codec.encode(record.rule))
            }
            return config
        }
        catch { throw ShouError("store_corrupt", "Configuration could not be decoded. Existing data was preserved.") }
    }
    private func saveConfiguration(_ config: Configuration) throws {
        var copy = config; copy.revision=Codec.id("config")
        try save(copy, collection: "configuration", id: "current")
    }
    private func protectingStore(_ workspace: Workspace) -> Workspace {
        var copy=workspace
        let prefix=workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        copy.protectedRelativePaths=store.protectedPaths.compactMap { path in
            if path == workspace.path { return "." }
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
        }
        return copy
    }
    private func save<T: Encodable>(_ value: T, collection: String, id: String) throws { try store.write(collection, id: id, data: Codec.encode(value)) }
    private func load<T: Decodable>(_ type: T.Type, collection: String, id: String) throws -> T {
        guard let data = try store.read(collection, id: id) else { throw ShouError("invalid_argument", "Record does not exist.", details: ["id": id]) }
        do { return try Codec.decode(type, from: data) }
        catch { throw ShouError("store_corrupt", "Stored record is invalid.", details: ["id": id]) }
    }
    public func addWorkspace(path: String, rootRef: String) throws -> Workspace {
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        guard rootRef.range(of: "^[a-z][a-z0-9-]{0,79}$", options: .regularExpression) != nil else { throw ShouError("invalid_argument", "Invalid logical workspace root reference.") }
        let lease = try store.lock(); defer { lease.release() }
        var config = try configuration()
        let identity = try filesystem.rootIdentity(path)
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        guard !config.workspaces.contains(where: { $0.rootRef == rootRef || $0.identity.sameObject(as: identity) }) else { throw ShouError("invalid_argument", "Workspace or root reference is already registered.") }
        let workspace = Workspace(id: Codec.id("ws"), rootRef: rootRef, path: path, identity: identity, exclusions: [], addedAt: now())
        config.workspaces.append(workspace); try saveConfiguration(config); return workspace
    }
    public func removeWorkspace(_ id: String) throws {
        let lease=try store.lock(); defer { lease.release() }
        var config=try configuration()
        guard config.workspaces.contains(where: { $0.id == id }) else { throw ShouError("invalid_argument", "Unknown workspace.") }
        config.workspaces.removeAll { $0.id == id }
        config.bindings.removeAll { $0.workspaceId == id }
        config.presets.removeAll { $0.workspaceId == id }
        try saveConfiguration(config)
    }
    public func workspace(_ id: String) throws -> Workspace {
        guard let workspace = try configuration().workspaces.first(where: { $0.id == id }) else { throw ShouError("invalid_argument", "Unknown workspace.", details: ["id": id]) }
        return workspace
    }
    public func setExclusion(workspaceId: String, pattern: String, remove: Bool) throws -> Workspace {
        try PathPattern.validate(pattern)
        let lease = try store.lock(); defer { lease.release() }
        var config = try configuration()
        guard let index = config.workspaces.firstIndex(where: { $0.id == workspaceId }) else { throw ShouError("invalid_argument", "Unknown workspace.") }
        if remove { config.workspaces[index].exclusions.removeAll { $0 == pattern } }
        else if !config.workspaces[index].exclusions.contains(pattern) { config.workspaces[index].exclusions.append(pattern) }
        try saveConfiguration(config); return config.workspaces[index]
    }
    public func importRule(_ data: Data, provenance: String = "local_file") throws -> RuleRecord {
        let rule = try CleanupRule.parse(data)
        guard !rule.id.hasPrefix(BuiltinCatalog.prefix) else { throw ShouError("invalid_rule", "The built-in rule namespace is reserved.") }
        let digest = try Digest.of(rule)
        let lease = try store.lock(); defer { lease.release() }
        var config = try configuration()
        if let old = config.rules.first(where: { $0.rule.id == rule.id && $0.rule.version == rule.version }) {
            guard old.digest == digest else { throw ShouError("version_conflict", "The same rule version already exists with different content.") }
            return old
        }
        let record = RuleRecord(rule: rule, digest: digest, importedAt: now(), provenance: provenance)
        config.rules.append(record); try saveConfiguration(config); return record
    }
    public func setRule(ruleId: String, workspaceId: String, enabled: Bool, version: String? = nil) throws -> RuleBinding {
        let lease = try store.lock(); defer { lease.release() }
        var config = try configuration()
        guard let registered = config.workspaces.first(where: { $0.id == workspaceId }) else { throw ShouError("invalid_argument", "Unknown workspace.") }
        let workspace=protectingStore(registered)
        let records = config.rules.filter { $0.rule.id == ruleId && (version == nil || $0.rule.version == version) }
        let builtin=try builtinRules(for: workspace).first { $0.id == ruleId && (version == nil || $0.version == version) }
        guard let rule=builtin ?? records.max(by: { $0.importedAt < $1.importedAt })?.rule else { throw ShouError("invalid_argument", "Unknown rule/version.") }
        guard rule.scope.rootRef == workspace.rootRef, rule.platforms.contains(filesystem.platform) else { throw ShouError("invalid_rule", "Rule root or platform does not match this workspace.") }
        config.bindings.removeAll { $0.ruleId == ruleId && $0.workspaceId == workspaceId }
        let binding = RuleBinding(workspaceId: workspaceId, ruleId: ruleId, version: rule.version, enabled: enabled)
        config.bindings.append(binding); try saveConfiguration(config); return binding
    }
    public func scan(workspaceId: String, ruleIds: [String] = [], previewRule: CleanupRule? = nil, scope: ScanScope = .full, budget: ScanBudget = ScanBudget(), progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanSnapshot {
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        try budget.validate()
        let config = try configuration()
        guard let registered = config.workspaces.first(where: { $0.id == workspaceId }) else { throw ShouError("invalid_argument", "Unknown workspace.") }
        let workspace=protectingStore(registered)
        guard try filesystem.rootIdentity(workspace.path).sameObject(as: workspace.identity) else { throw ShouError("access_expired", "Workspace identity changed; select the workspace again.") }
        var rules: [CleanupRule] = []
        if let previewRule {
            guard previewRule.scope.rootRef == workspace.rootRef && previewRule.platforms.contains(filesystem.platform) else { throw ShouError("invalid_rule", "Preview rule root or platform does not match.") }
            rules=[previewRule]
        } else {
            rules=try activeRules(config, workspaceId: workspaceId).filter { ruleIds.isEmpty || ruleIds.contains($0.id) }
            if !ruleIds.allSatisfy({ id in rules.contains { $0.id == id } }) { throw ShouError("invalid_argument", "Requested rule is not enabled in this workspace.") }
        }
        let tree = try inspect(workspace.path, rules: rules, scope: scope, budget: budget, progress: progress)
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        progress(ScanProgress(stage: "analysis", entryCount: tree.entries.count))
        let referenceTime=now()
        let snapshot = ScanSnapshot(id: Codec.id("scan"), workspace: workspace, configurationDigest: try Digest.of(config), createdAt: referenceTime, status: (tree.discoveryComplete ?? tree.complete) ? "complete" : "partial", previewOnly: previewRule != nil, caseSensitive: tree.caseSensitive, entries: tree.entries,
            candidates: try Analysis.candidates(tree: tree, workspace: workspace, rules: rules, now: referenceTime, blockedRules: ApplicationSafety.blockedRules(rules.map(\.id), activity: applicationActivity), artifactEvidence: artifactEvidence, artifactHomeDirectory: homeDirectory, maxSeconds: budget.maxSeconds), issues: tree.issues, budget: budget, completedPaths: tree.completedPaths, treeComplete: tree.complete, scope: scope)
        progress(ScanProgress(stage: "saving", entryCount: tree.entries.count))
        try save(snapshot, collection: "scans", id: snapshot.id)
        return snapshot
    }
    public func scanSnapshot(_ id: String) throws -> ScanSnapshot { try load(ScanSnapshot.self, collection: "scans", id: id) }
    public func createPlan(scanId: String, candidateIds: [String]) throws -> CleanupPlan {
        guard !candidateIds.isEmpty, Set(candidateIds).count == candidateIds.count else { throw ShouError("invalid_argument", "Explicit, unique candidate IDs are required.") }
        let snapshot = try scanSnapshot(scanId)
        let budget=snapshot.budget ?? ScanBudget()
        try budget.validate()
        guard !snapshot.previewOnly else { throw ShouError("partial_result", "Draft previews cannot produce executable plans.") }
        let config = try configuration()
        guard try Digest.of(config) == snapshot.configurationDigest else { throw ShouError("plan_stale", "Configuration changed; scan again.") }
        let eligibleRules = try activeRules(config, workspaceId: snapshot.workspace.id)
        let blocked=ApplicationSafety.blockedRules(eligibleRules.map(\.id), activity: applicationActivity)
        let reviewed = try Analysis.candidates(tree: TreeSnapshot(entries: snapshot.entries, complete: snapshot.treeComplete ?? (snapshot.status == "complete"), issues: snapshot.issues, caseSensitive: snapshot.caseSensitive, completedPaths: snapshot.completedPaths), workspace: protectingStore(snapshot.workspace), rules: eligibleRules, now: snapshot.createdAt, blockedRules: blocked, artifactEvidence: artifactEvidence, artifactHomeDirectory: homeDirectory, maxSeconds: budget.maxSeconds)
        var items: [PlanItem] = []
        for id in candidateIds {
            guard let candidate = snapshot.candidates.first(where: { $0.id == id }), candidate.eligible else { throw ShouError("invalid_argument", "Candidate is missing, protected, excluded, or unclassified.", details: ["candidate": id]) }
            let path = candidate.relativePath
            if let reason=candidate.ruleIds.compactMap({ blocked[$0] }).sorted().first {
                throw ShouError(reason, "Quit the affected application and scan again before cleanup.")
            }
            guard reviewed.contains(where: { $0.relativePath == path && $0.eligible && $0.manifestDigest == candidate.manifestDigest && $0.ruleVersions == candidate.ruleVersions }) else {
                throw ShouError("store_corrupt", "Candidate policy evidence could not be reproduced.")
            }
            guard !items.contains(where: { $0.candidate.relativePath.hasPrefix(path + "/") || path.hasPrefix($0.candidate.relativePath + "/") }) else { throw ShouError("invalid_argument", "Parent and child targets cannot be selected together.") }
            let manifest = Analysis.subtree(snapshot.entries, path: path)
            guard try Digest.of(manifest) == candidate.manifestDigest else { throw ShouError("store_corrupt", "Candidate manifest does not match its snapshot.") }
            items.append(PlanItem(id: Codec.id("item"), candidate: candidate, manifest: manifest))
        }
        var plan = CleanupPlan(id: Codec.id("plan"), scanId: scanId, workspace: snapshot.workspace, configurationDigest: snapshot.configurationDigest, createdAt: now(), expiresAt: now().addingTimeInterval(600), items: items)
        plan.scanBudget=snapshot.budget
        plan.scanScope=snapshot.scope
        plan.digest = try plan.calculatedDigest()
        try save(plan, collection: "plans", id: plan.id); return plan
    }
    public func plan(_ id: String) throws -> CleanupPlan {
        let plan = try load(CleanupPlan.self, collection: "plans", id: id)
        guard try plan.calculatedDigest() == plan.digest else { throw ShouError("store_corrupt", "Plan digest verification failed.") }
        return plan
    }
    public func execute(planId: String, confirmedDigest: String, entryPoint: String, progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> ExecutionReceipt {
        let lease = try store.lock(); defer { lease.release() }
        var plan = try plan(planId)
        guard plan.executionId == nil else { throw ShouError("already_executed", "This plan already has an execution record.", details: ["execution_id": plan.executionId ?? ""]) }
        guard confirmedDigest == plan.digest else { throw ShouError("confirmation_required", "Confirmation does not match the current plan.") }
        guard plan.expiresAt > now(), try Digest.of(configuration()) == plan.configurationDigest,
              try filesystem.rootIdentity(plan.workspace.path).sameObject(as: plan.workspace.identity) else { throw ShouError("plan_stale", "Plan expired or workspace/configuration changed; preview again.") }
        guard filesystem.supportsTrash else { throw ShouError("capability_unavailable", filesystem.trashUnavailableReason ?? "System Trash is unavailable; no deletion fallback is permitted.") }
        let currentConfig = try configuration()
        guard let registered = currentConfig.workspaces.first(where: { $0.id == plan.workspace.id }),
              registered.path == plan.workspace.path, registered.exclusions == plan.workspace.exclusions else { throw ShouError("plan_stale", "Plan workspace does not match its registered binding.") }
        // Persisted plans are data, never authority. Reproduce policy from fresh
        // coverage; every selected subtree must be complete independently.
        progress(ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: plan.items.count, path: registered.path))
        let currentRules=try activeRules(currentConfig, workspaceId: registered.id)
        let budget=plan.scanBudget ?? ScanBudget()
        try budget.validate()
        let currentTree = try inspect(registered.path, rules: currentRules, scope: plan.scanScope ?? .full, budget: budget)
        let currentEntries=Dictionary(uniqueKeysWithValues: currentTree.entries.map { ($0.path, $0) })
        let currentCandidates = try Analysis.candidates(tree: currentTree, workspace: protectingStore(registered), rules: currentRules, now: now(), artifactEvidence: artifactEvidence, artifactHomeDirectory: homeDirectory, maxSeconds: budget.maxSeconds)
        for item in plan.items {
            try PathPattern.validate(item.candidate.relativePath)
            guard currentCandidates.contains(where: { $0.relativePath == item.candidate.relativePath && $0.eligible && $0.manifestDigest == item.candidate.manifestDigest && $0.ruleVersions == item.candidate.ruleVersions }),
                  try Digest.of(item.manifest) == item.candidate.manifestDigest else { throw ShouError("plan_stale", "Current policy or full manifest no longer permits this target.") }
            try verify(path: plan.workspace.path + "/" + item.candidate.relativePath, manifest: item.manifest)
        }
        if Task.isCancelled { throw ShouError("cancelled", "Cleanup stopped before any files were moved.") }
        var receipt = ExecutionReceipt(id: Codec.id("execution"), planId: plan.id, workspace: plan.workspace, createdAt: now(), entryPoint: entryPoint, state: "executing", items: plan.items.map {
            ItemReceipt(id: $0.id, originalPath: plan.workspace.path + "/" + $0.candidate.relativePath, relativePath: $0.candidate.relativePath, trashPath: nil, manifest: $0.manifest, state: "pending", allocatedBytesEstimate: $0.candidate.allocatedBytesEstimate, error: nil)
        }, volumeAvailableBefore: filesystem.availableBytes(plan.workspace.path), volumeAvailableAfter: nil)
        try save(receipt, collection: "history", id: receipt.id)
        plan.executionId=receipt.id; plan.state="executing"
        try save(plan, collection: "plans", id: plan.id)
        for index in receipt.items.indices {
            if Task.isCancelled { receipt.state="cancelled"; break }
            progress(ExecutionProgress(stage: "moving", processedCount: index, itemCount: receipt.items.count, path: receipt.items[index].originalPath))
            let blocked=ApplicationSafety.blockedRules(plan.items[index].candidate.ruleIds, activity: applicationActivity)
            if let reason=blocked.values.sorted().first {
                receipt.items[index].state="skipped"; receipt.items[index].error=reason
                try save(receipt, collection: "history", id: receipt.id)
                progress(ExecutionProgress(stage: "moving", processedCount: index + 1, itemCount: receipt.items.count, path: receipt.items[index].originalPath))
                continue
            }
            do {
                let policy=ArtifactSafety.sourcePolicy(path: plan.items[index].candidate.relativePath, manifest: plan.items[index].manifest,
                    entries: currentEntries, workspace: protectingStore(registered),
                    rules: currentRules.filter { plan.items[index].candidate.ruleIds.contains($0.id) }, homeDirectory: homeDirectory, evidence: artifactEvidence)
                guard policy.reasons.isEmpty else { throw ShouError("plan_stale", "Artifact ownership or build activity changed before cleanup.", details: ["reasons": policy.reasons.joined(separator: ",")]) }
                let moved = try filesystem.moveToTrash(receipt.items[index].originalPath, expected: receipt.items[index].manifest)
                receipt.items[index].trashPath=moved.path; receipt.items[index].manifest=moved.manifest
                receipt.items[index].state=moved.verified ? "trashed" : "unknown"
                if !moved.verified { receipt.items[index].error="Moved identity or contents could not be verified." }
            } catch {
                receipt.items[index].state="failed"; receipt.items[index].error=String(describing: error)
            }
            try save(receipt, collection: "history", id: receipt.id)
            progress(ExecutionProgress(stage: "moving", processedCount: index + 1, itemCount: receipt.items.count, path: receipt.items[index].originalPath))
            if receipt.items[index].state != "trashed" { break }
        }
        if receipt.state != "cancelled" { receipt.state=receipt.items.allSatisfy { $0.state == "trashed" } ? "completed" : "partial" }
        receipt.volumeAvailableAfter=filesystem.availableBytes(plan.workspace.path)
        try save(receipt, collection: "history", id: receipt.id)
        plan.state=receipt.state; try save(plan, collection: "plans", id: plan.id)
        return receipt
    }
    private func inspect(_ path: String, rules: [CleanupRule], scope: ScanScope, budget: ScanBudget, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> TreeSnapshot {
        if scope == .cleanup { return try filesystem.inspectCleanup(path, rules: rules, budget: budget, cancelled: { Task.isCancelled }, progress: progress) }
        return try filesystem.inspect(path, budget: budget, cancelled: { Task.isCancelled }, progress: progress)
    }
    private func builtinRules(for workspace: Workspace) throws -> [CleanupRule] { try BuiltinCatalog.rules(for: workspace, homeDirectory: homeDirectory, platform: filesystem.platform) }
    public func builtinRules(workspaceId: String) throws -> [CleanupRule] { try builtinRules(for: workspace(workspaceId)) }
    private func activeRules(_ config: Configuration, workspaceId: String) throws -> [CleanupRule] {
        guard let workspace=config.workspaces.first(where: { $0.id == workspaceId }) else { throw ShouError("invalid_argument", "Unknown workspace.") }
        let builtins=try builtinRules(for: workspace).filter { rule in
            !config.bindings.contains { $0.workspaceId == workspaceId && $0.ruleId == rule.id && !$0.enabled }
        }
        return try builtins + config.bindings.filter { $0.workspaceId == workspaceId && $0.enabled && !$0.ruleId.hasPrefix(BuiltinCatalog.prefix) }.map { binding in
            guard let record=config.rules.first(where: { $0.rule.id == binding.ruleId && $0.rule.version == binding.version }) else { throw ShouError("store_corrupt", "Enabled rule definition is missing.") }
            return record.rule
        }
    }
    private func verify(path: String, manifest: [FileEntry], trashReceipt: Bool = false) throws {
        let current = try filesystem.inspect(path, budget: ScanBudget(maxEntries: max(100_000, manifest.count + 1), maxSeconds: 180), cancelled: { Task.isCancelled })
        guard current.complete, current.entries.count == manifest.count,
              zip(current.entries, manifest).allSatisfy({ observed, saved in
                  observed == saved || (trashReceipt && observed.matchesTrashRoot(as: saved))
              }) else { throw ShouError("plan_stale", "Target identity or full directory manifest changed.", details: ["path": path]) }
    }
    public func history() throws -> [ExecutionReceipt] { try store.ids("history").map { try history($0) }.sorted { $0.createdAt > $1.createdAt } }
    public func history(_ id: String) throws -> ExecutionReceipt { try load(ExecutionReceipt.self, collection: "history", id: id) }
    public func followUps() throws -> [FollowUpReceipt] { try store.ids("followups").map { try load(FollowUpReceipt.self, collection: "followups", id: $0) } }
    public func followUpDigest(executionId: String, itemIds: [String], action: String) throws -> String {
        guard ["restore", "purge"].contains(action), !itemIds.isEmpty, Set(itemIds).count == itemIds.count else { throw ShouError("invalid_argument", "Select explicit receipt items and a supported action.") }
        let receipt = try history(executionId)
        guard itemIds.allSatisfy({ id in receipt.items.contains { $0.id == id && $0.state == "trashed" } }) else { throw ShouError("invalid_argument", "Only verified trashed items can be restored or permanently removed.") }
        return try Digest.of(JSONValue.object(["receipt": try .from(receipt), "items": .array(itemIds.sorted().map(JSONValue.string)), "action": .string(action)]))
    }
    public func followUp(executionId: String, itemIds: [String], action: String, confirmedDigest: String) throws -> [FollowUpReceipt] {
        let lease = try store.lock(); defer { lease.release() }
        guard try followUpDigest(executionId: executionId, itemIds: itemIds, action: action) == confirmedDigest else { throw ShouError("confirmation_required", "Follow-up confirmation does not match.") }
        let receipt = try history(executionId)
        let existing = try followUps()
        var results: [FollowUpReceipt] = []
        for item in receipt.items where itemIds.contains(item.id) {
            guard !existing.contains(where: { $0.itemId == item.id && ($0.state == "completed" || $0.state == "pending") }), let trashPath = item.trashPath else { throw ShouError("already_executed", "Receipt item already has a follow-up operation.") }
            try PathPattern.validate(item.relativePath)
            guard item.originalPath == receipt.workspace.path + "/" + item.relativePath, filesystem.isTrashLocation(trashPath) else {
                throw ShouError("store_corrupt", "Receipt paths do not identify a workspace item and a system Trash location.")
            }
            var result = FollowUpReceipt(id: Codec.id("followup"), executionId: executionId, itemId: item.id, action: action, createdAt: now(), state: "pending", resultingPath: nil, error: nil)
            try verify(path: trashPath, manifest: item.manifest, trashReceipt: true)
            try save(result, collection: "followups", id: result.id)
            do {
                if action == "restore" {
                    guard try filesystem.rootIdentity(receipt.workspace.path).sameObject(as: receipt.workspace.identity) else { throw ShouError("access_expired", "Original workspace identity changed.") }
                    try filesystem.restore(trashPath, to: item.originalPath, expected: item.manifest); result.resultingPath=item.originalPath
                } else { try filesystem.purge(trashPath, expected: item.manifest) }
                result.state="completed"
            } catch { result.state="failed"; result.error=String(describing: error) }
            try save(result, collection: "followups", id: result.id); results.append(result)
        }
        return results
    }
    public func savePreset(name: String, workspaceId: String, ruleIds: [String]) throws -> Preset {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !ruleIds.isEmpty else { throw ShouError("invalid_argument", "A preset requires a name and explicit rules.") }
        let lease = try store.lock(); defer { lease.release() }
        var config = try configuration()
        let enabled=try activeRules(config, workspaceId: workspaceId)
        guard ruleIds.allSatisfy({ id in enabled.contains { $0.id == id } }) else { throw ShouError("invalid_argument", "Preset rules must be enabled in this workspace.") }
        let preset = Preset(id: Codec.id("preset"), name: name, workspaceId: workspaceId, ruleIds: Array(Set(ruleIds)).sorted())
        config.presets.append(preset); try saveConfiguration(config); return preset
    }
}
