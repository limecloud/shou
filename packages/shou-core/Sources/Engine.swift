import Foundation

public actor ShouEngine {
    let store: any RecordStore
    let filesystem: any PlatformFileSystem
    let homeDirectory: URL
    private let applicationActivity: any ApplicationActivityChecking
    private let artifactEvidence: any ArtifactEvidenceChecking
    let now: @Sendable () -> Date
    let applicationCatalog: any ApplicationCatalogReading
    let uninstallEvidence: any ApplicationUninstallChecking
    var lastRecordMaintenance: Date?
    func scanWorker(workspaceId: String, budget: ScanBudget, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanSnapshot {
        let worker=ShouEngine(store: store, filesystem: filesystem, applicationActivity: applicationActivity, artifactEvidence: artifactEvidence,
            applicationCatalog: applicationCatalog, uninstallEvidence: uninstallEvidence, homeDirectory: homeDirectory, now: now)
        return try await worker.scanPreparedWorkspace(workspaceId: workspaceId, budget: budget, progress: progress)
    }
    private func scanPreparedWorkspace(workspaceId: String, budget: ScanBudget, progress: @escaping @Sendable (ScanProgress) -> Void) throws -> ScanSnapshot {
        lastRecordMaintenance=now()
        return try scan(workspaceId: workspaceId, scope: .cleanup, budget: budget, progress: progress)
    }
    public init(store: any RecordStore, filesystem: any PlatformFileSystem, applicationActivity: any ApplicationActivityChecking = UnavailableApplicationActivity(), artifactEvidence: any ArtifactEvidenceChecking = UnavailableArtifactEvidence(), applicationCatalog: any ApplicationCatalogReading = UnavailableApplicationCatalog(), uninstallEvidence: any ApplicationUninstallChecking = UnavailableApplicationUninstallEvidence(), homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store=store; self.filesystem=filesystem; self.applicationActivity=applicationActivity; self.artifactEvidence=artifactEvidence; self.applicationCatalog=applicationCatalog; self.uninstallEvidence=uninstallEvidence
        self.homeDirectory=filesystem.platform == "windows" ? (try? filesystem.normalizedPath(homeDirectory.path)).map { URL(fileURLWithPath: $0) } ?? homeDirectory : homeDirectory
        self.now=now
    }
    public func configuration() throws -> Configuration {
        guard let data = try store.read("configuration", id: "current") else {
            var empty=Configuration()
            empty.revision="unconfigured"
            return empty
        }
        do {
            let config=try Codec.decode(Configuration.self, from: data)
            guard [1, 2].contains(config.version), config.version == 2 || (config.globalExclusions ?? []).isEmpty else { throw ShouError("store_corrupt", "Unsupported configuration version.") }
            for pattern in config.globalExclusions ?? [] { try PathPattern.validate(pattern) }
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
        // Older builds must refuse a policy they cannot enforce, even after its
        // last global exclusion is removed. Version 1 remains readable here.
        if !(copy.globalExclusions ?? []).isEmpty { copy.version=2 }
        try save(copy, collection: "configuration", id: "current")
    }
    private func protectedWorkspace(_ workspace: Workspace, configuration: Configuration) -> Workspace {
        var copy=workspace
        copy.exclusions=ExclusionSettings(globalPatterns: configuration.globalExclusions ?? [], workspaceId: workspace.id, workspacePatterns: workspace.exclusions).effectivePatterns
        let prefix=workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        copy.protectedRelativePaths=store.protectedPaths.compactMap { path in
            let compared=filesystem.caseSensitivePaths ? path : path.lowercased()
            let root=filesystem.caseSensitivePaths ? workspace.path : workspace.path.lowercased()
            let start=filesystem.caseSensitivePaths ? prefix : prefix.lowercased()
            if compared == root { return "." }
            return compared.hasPrefix(start) ? String(path.dropFirst(prefix.count)) : nil
        }
        return copy
    }
    /// A mounted macOS volume may receive a different `st_dev` value after a
    /// remount while keeping the same directory inode. The persisted workspace
    /// binding must survive that benign remount, but it must still reject a
    /// replaced directory. Only the root binding uses this compatibility rule;
    /// target manifests continue to require their exact device/inode evidence.
    private func rootIdentityMatches(_ current: FileEntry, _ saved: FileEntry) -> Bool {
        current.sameObject(as: saved) ||
            (current.windowsIdentity == nil && saved.windowsIdentity == nil &&
             current.kind == "directory" && saved.kind == "directory" &&
             current.inode == saved.inode && current.owner == saved.owner)
    }

    private func refreshedWorkspace(_ config: Configuration, index: Int, current: FileEntry) throws -> Workspace {
        let saved=config.workspaces[index]
        guard rootIdentityMatches(current, saved.identity) else {
            throw ShouError("access_expired", "Workspace identity changed; select the workspace again.")
        }
        // Keep the durable configuration digest stable for the scan. The
        // current root identity is carried by this snapshot-only workspace;
        // silently rewriting configuration here would invalidate the snapshot
        // immediately after it was saved.
        var refreshed=saved
        refreshed.identity=current
        return refreshed
    }
    private func save<T: Encodable>(_ value: T, collection: String, id: String) throws { try store.write(collection, id: id, data: Codec.encode(value)) }
    private func load<T: Decodable>(_ type: T.Type, collection: String, id: String) throws -> T {
        guard let data = try store.read(collection, id: id) else { throw ShouError("invalid_argument", "Record does not exist.", details: ["id": id]) }
        do { return try Codec.decode(type, from: data) }
        catch { throw ShouError("store_corrupt", "Stored record is invalid.", details: ["id": id]) }
    }
    public func addWorkspace(path: String, rootRef: String) throws -> Workspace {
        let path=try filesystem.normalizedPath(path)
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
    public func workspaceAccessible(_ id: String) throws -> Bool {
        let workspace=try workspace(id)
        do { return rootIdentityMatches(try filesystem.rootIdentity(workspace.path), workspace.identity) }
        catch { return false }
    }
    public func exclusionSettings(workspaceId: String? = nil) throws -> ExclusionSettings {
        let config=try configuration()
        let root: Workspace?
        if let workspaceId {
            guard let workspace=config.workspaces.first(where: { $0.id == workspaceId }) else { throw ShouError("invalid_argument", "Unknown workspace.") }
            root=workspace
        } else { root=nil }
        return ExclusionSettings(globalPatterns: config.globalExclusions ?? [], workspaceId: root?.id, workspacePatterns: root?.exclusions ?? [])
    }
    public func setGlobalExclusion(pattern: String, remove: Bool) throws -> [String] {
        try PathPattern.validate(pattern)
        let lease=try store.lock(); defer { lease.release() }
        var config=try configuration()
        let previous=config.globalExclusions ?? []
        var patterns=previous
        if remove { patterns.removeAll { $0 == pattern } }
        else if !patterns.contains(pattern) { patterns.append(pattern) }
        if patterns != previous {
            config.globalExclusions=patterns.isEmpty ? nil : patterns
            try saveConfiguration(config)
        }
        return patterns
    }
    public func setExclusion(workspaceId: String, pattern: String, remove: Bool, project: String? = nil) throws -> Workspace {
        let pattern=try project.map { try ExclusionPattern.scopedToProject($0, pattern: pattern) } ?? pattern
        try PathPattern.validate(pattern)
        let lease = try store.lock(); defer { lease.release() }
        var config = try configuration()
        guard let index = config.workspaces.firstIndex(where: { $0.id == workspaceId }) else { throw ShouError("invalid_argument", "Unknown workspace.") }
        if remove { config.workspaces[index].exclusions.removeAll { $0 == pattern } }
        else if !config.workspaces[index].exclusions.contains(pattern) { config.workspaces[index].exclusions.append(pattern) }
        try saveConfiguration(config); return config.workspaces[index]
    }
    public func importRule(_ data: Data, provenance: String = "local_file", requireNewVersion: Bool = false) throws -> RuleRecord {
        let rule = try CleanupRule.parse(data)
        guard !rule.id.hasPrefix(BuiltinCatalog.prefix) else { throw ShouError("invalid_rule", "The built-in rule namespace is reserved.") }
        let digest = try Digest.of(rule)
        let lease = try store.lock(); defer { lease.release() }
        var config = try configuration()
        if let old = config.rules.first(where: { $0.rule.id == rule.id && $0.rule.version == rule.version }) {
            guard !requireNewVersion else { throw ShouError("version_conflict", "Choose an unused rule version. Existing versions cannot be overwritten.") }
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
        let workspace=protectedWorkspace(registered, configuration: config)
        let records = config.rules.filter { $0.rule.id == ruleId && (version == nil || $0.rule.version == version) }
        let definitions=try builtinRules(for: workspace) + installedCacheDiscovery(for: workspace).rules
        let builtin=definitions.first { $0.id == ruleId && (version == nil || $0.version == version) }
        guard let rule=builtin ?? records.max(by: { $0.importedAt < $1.importedAt })?.rule else { throw ShouError("invalid_argument", "Unknown rule/version.") }
        guard rule.scope.rootRef == workspace.rootRef, rule.platforms.contains(filesystem.platform) else { throw ShouError("invalid_rule", "Rule root or platform does not match this workspace.") }
        config.bindings.removeAll { $0.ruleId == ruleId && $0.workspaceId == workspaceId }
        let binding = RuleBinding(workspaceId: workspaceId, ruleId: ruleId, version: rule.version, enabled: enabled)
        config.bindings.append(binding); try saveConfiguration(config); return binding
    }
    public func scan(workspaceId: String, ruleIds: [String] = [], previewRule: CleanupRule? = nil, scope: ScanScope = .full, budget: ScanBudget = ScanBudget(), progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanSnapshot {
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        try budget.validate()
        maintainDerivedRecordsIfNeeded()
        let config = try configuration()
        guard let index=config.workspaces.firstIndex(where: { $0.id == workspaceId }) else { throw ShouError("invalid_argument", "Unknown workspace.") }
        let currentIdentity=try filesystem.rootIdentity(config.workspaces[index].path)
        let registered=try refreshedWorkspace(config, index: index, current: currentIdentity)
        let workspace=protectedWorkspace(registered, configuration: config)
        var rules: [CleanupRule] = []
        let discovered=previewRule == nil ? try installedCacheDiscovery(for: workspace) : InstalledApplicationCaches.Discovery()
        if let previewRule {
            guard previewRule.scope.rootRef == workspace.rootRef && previewRule.platforms.contains(filesystem.platform) else { throw ShouError("invalid_rule", "Preview rule root or platform does not match.") }
            rules=[previewRule]
        } else {
            rules=try activeRules(config, workspaceId: workspaceId, additionalBuiltins: discovered.rules).filter { ruleIds.isEmpty || ruleIds.contains($0.id) }
            if !ruleIds.allSatisfy({ id in rules.contains { $0.id == id } }) { throw ShouError("invalid_argument", "Requested rule is not enabled in this workspace.") }
        }
        let reporter=ScanProgressReporter(output: progress)
        let tree = try inspect(workspace.path, rules: rules, scope: scope, budget: budget, progress: { update in
            // Worker sealing and transport still belong to discovery. Their local
            // percentages must not be presented as overall rule-scan completion.
            reporter.report(ScanProgress(stage: "scanning", entryCount: update.entryCount, currentPath: update.currentPath, limitReached: update.limitReached))
        })
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        reporter.report(ScanProgress(stage: "analysis", entryCount: tree.entries.count, currentPath: workspace.path, completedUnitCount: 1, totalUnitCount: 3))
        let referenceTime=now()
        let installedCaches=discovered.evidence.filter { evidence in rules.contains { $0.id == evidence.ruleId } }
        let blocked=try ApplicationSafety.blockedRules(rules.map(\.id), activity: applicationActivity).merging(
            InstalledApplicationCaches.blocked(installedCaches, workspace: workspace, activity: uninstallEvidence), uniquingKeysWith: { _, value in value })
        let snapshot = ScanSnapshot(id: Codec.id("scan"), workspace: workspace, configurationDigest: try Digest.of(config), createdAt: referenceTime, status: (tree.discoveryComplete ?? tree.complete) ? "complete" : "partial", previewOnly: previewRule != nil, caseSensitive: tree.caseSensitive, entries: tree.entries,
            candidates: try Analysis.candidates(tree: tree, workspace: workspace, rules: rules, now: referenceTime, blockedRules: blocked, artifactEvidence: artifactEvidence, artifactHomeDirectory: homeDirectory, maxSeconds: budget.maxSeconds), issues: tree.issues + discovered.issues, budget: budget, completedPaths: tree.completedPaths, treeComplete: tree.complete, scope: scope, installedApplicationCaches: installedCaches.isEmpty ? nil : installedCaches)
        reporter.report(ScanProgress(stage: "analysis", entryCount: tree.entries.count, currentPath: workspace.path, completedUnitCount: 2, totalUnitCount: 3))
        reporter.report(ScanProgress(stage: "saving", entryCount: tree.entries.count, currentPath: workspace.path, completedUnitCount: 2, totalUnitCount: 3))
        try save(snapshot, collection: "scans", id: snapshot.id)
        reporter.report(ScanProgress(stage: "saving", entryCount: tree.entries.count, currentPath: workspace.path, completedUnitCount: 3, totalUnitCount: 3))
        return snapshot
    }
    public func scanSnapshot(_ id: String) throws -> ScanSnapshot { try load(ScanSnapshot.self, collection: "scans", id: id) }
    /// Re-measure one previously discovered target under its original authority.
    /// Narrow patterns control reads only; policy always uses canonical rules.
    public func scanCleanupTarget(scanId: String, candidateId: String, budget: ScanBudget = ScanBudget(maxEntries: 1_000_000, maxSeconds: 120),
                                  progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanSnapshot {
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        try budget.validate()
        let previous=try scanSnapshot(scanId)
        guard !previous.previewOnly else { throw ShouError("partial_result", "Draft previews cannot authorize target scans.") }
        guard previous.scope == .cleanup else { throw ShouError("invalid_argument", "Select an incomplete cleanup scan.") }
        let config=try configuration(), configurationDigest=try Digest.of(config)
        guard configurationDigest == previous.configurationDigest else { throw ShouError("plan_stale", "Configuration changed; scan again.") }
        guard let index=config.workspaces.firstIndex(where: { $0.id == previous.workspace.id }),
              config.workspaces[index].path == previous.workspace.path, config.workspaces[index].rootRef == previous.workspace.rootRef,
              let candidate=previous.candidates.first(where: { $0.id == candidateId }), !candidate.ruleIds.isEmpty,
              candidate.reasons.contains("incomplete_scan"),
              let savedTarget=previous.entries.first(where: { $0.path == candidate.relativePath && $0.kind == "directory" }) else {
            throw ShouError("invalid_argument", "Select a previously matched, incomplete cleanup directory.")
        }
        let path=candidate.relativePath
        try PathPattern.validate(path, target: true)
        guard !path.contains("*"), !path.contains("?") else {
            throw ShouError("capability_unavailable", "A target path containing wildcard characters requires a new workspace scan.")
        }
        let oldTree=TreeSnapshot(entries: previous.entries, complete: previous.treeComplete ?? (previous.status == "complete"),
            issues: previous.issues, caseSensitive: previous.caseSensitive, completedPaths: previous.completedPaths)
        guard !oldTree.isComplete(at: path) else { throw ShouError("invalid_argument", "This cleanup directory is already completely measured.") }
        let rootIdentity=try filesystem.rootIdentity(previous.workspace.path)
        guard rootIdentityMatches(rootIdentity, previous.workspace.identity), rootIdentity.hasSameOwner(as: previous.workspace.identity) else { throw ShouError("plan_stale", "Workspace identity changed; scan again.") }
        let workspace=protectedWorkspace(try refreshedWorkspace(config, index: index, current: rootIdentity), configuration: config)
        let installedCaches=try InstalledApplicationCaches.selected(previous.installedApplicationCaches, ruleIds: candidate.ruleIds)
        try revalidateInstalledCaches(installedCaches, workspace: workspace)
        let rules=try activeRules(config, workspaceId: workspace.id,
            additionalBuiltins: installedCaches.map { try InstalledApplicationCaches.rule($0, workspace: workspace) })
        let selected=rules.filter { candidate.ruleIds.contains($0.id) && candidate.ruleVersions[$0.id] == $0.version }
        // Incomplete evidence proves matching, never source safety or completeness.
        // Keep every old path incomplete while reproducing the original match.
        let proof=try Analysis.candidates(tree: TreeSnapshot(entries: previous.entries, complete: false, issues: [],
            caseSensitive: previous.caseSensitive), workspace: workspace, rules: selected, now: previous.createdAt, maxSeconds: budget.maxSeconds)
        guard proof.contains(where: { $0.relativePath == path && $0.ruleIds == candidate.ruleIds && $0.ruleVersions == candidate.ruleVersions }) else {
            throw ShouError("store_corrupt", "The original cleanup match could not be reproduced.")
        }
        let absolutePath=workspace.path + "/" + path
        let targetIdentity=try filesystem.cleanupTargetIdentity(absolutePath)
        guard targetIdentity.sameObject(as: savedTarget), targetIdentity.hasSameOwner(as: savedTarget) else {
            throw ShouError("plan_stale", "Cleanup directory identity changed; scan again.")
        }
        let narrowRules=selected.map { rule in var copy=rule; copy.match.relativePatterns=[path]; return copy }
        let reporter=ScanProgressReporter(output: progress)
        let measured=try inspect(workspace.path, rules: narrowRules, scope: .cleanup, budget: budget, progress: { update in
            reporter.report(ScanProgress(stage: "scanning", entryCount: update.entryCount, currentPath: update.currentPath, limitReached: update.limitReached))
        })
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        // A sparse result can complete only this subtree. Old siblings and root
        // completion proofs never become part of the new snapshot.
        let components=path.split(separator: "/")
        let ancestors=Set(components.indices.dropFirst().map { components.prefix($0).joined(separator: "/") } + ["."])
        let entries=measured.entries.filter { entry in
            entry.path == path || entry.path.hasPrefix(path + "/") || ancestors.contains(entry.path) ||
                (entry.kind != "directory" && ancestors.contains(StorageIndex.parent(entry.path)))
        }
        guard let observed=entries.first(where: { $0.path == path && $0.kind == "directory" }),
              observed.sameObject(as: targetIdentity), observed.hasSameOwner(as: targetIdentity) else {
            if measured.issues.contains("resource_limit") { throw ShouError("resource_limit", "The scan limit was reached before the cleanup directory could be measured.") }
            throw ShouError("plan_stale", "Cleanup directory or its project markers changed; scan again.")
        }
        let tree=TreeSnapshot(entries: entries, complete: false, issues: measured.issues, caseSensitive: measured.caseSensitive,
            completedPaths: measured.isComplete(at: path) ? [path] : [])
        reporter.report(ScanProgress(stage: "analysis", entryCount: entries.count, currentPath: absolutePath, completedUnitCount: 1, totalUnitCount: 3))
        let referenceTime=now()
        let blocked=try ApplicationSafety.blockedRules(rules.map(\.id), activity: applicationActivity).merging(
            InstalledApplicationCaches.blocked(installedCaches, workspace: workspace, activity: uninstallEvidence), uniquingKeysWith: { _, value in value })
        let candidates=try Analysis.candidates(tree: tree, workspace: workspace, rules: rules, now: referenceTime, blockedRules: blocked,
            artifactEvidence: artifactEvidence, artifactHomeDirectory: homeDirectory, maxSeconds: budget.maxSeconds).filter {
                $0.relativePath == path || $0.relativePath.hasPrefix(path + "/")
            }
        guard candidates.contains(where: { $0.relativePath == path && !$0.ruleIds.isEmpty }) else {
            throw ShouError("plan_stale", "Cleanup rules or project markers no longer match this directory; scan again.")
        }
        let snapshot=ScanSnapshot(id: Codec.id("scan"), workspace: workspace, configurationDigest: configurationDigest, createdAt: referenceTime,
            status: tree.isComplete(at: path) ? "complete" : "partial", previewOnly: false, caseSensitive: tree.caseSensitive, entries: entries,
            candidates: candidates, issues: tree.issues, budget: budget, completedPaths: tree.completedPaths, treeComplete: false, scope: .cleanup,
            installedApplicationCaches: installedCaches.isEmpty ? nil : installedCaches)
        reporter.report(ScanProgress(stage: "saving", entryCount: entries.count, currentPath: absolutePath, completedUnitCount: 2, totalUnitCount: 3))
        let lease=try store.lock(); defer { lease.release() }
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        var expectedTarget=observed.metadata; expectedTarget.path="."
        guard try Digest.of(configuration()) == configurationDigest,
              rootIdentityMatches(try filesystem.rootIdentity(workspace.path), rootIdentity),
              (try filesystem.cleanupTargetIdentity(absolutePath)) == expectedTarget else {
            throw ShouError("plan_stale", "Configuration or directory identity changed during the scan; scan again.")
        }
        try save(snapshot, collection: "scans", id: snapshot.id)
        reporter.report(ScanProgress(stage: "saving", entryCount: entries.count, currentPath: absolutePath, completedUnitCount: 3, totalUnitCount: 3))
        return snapshot
    }
    public func rulePreviewBenefits(scanId: String) throws -> RulePreviewBenefits {
        let scan=try scanSnapshot(scanId), config=try configuration()
        guard scan.previewOnly, scan.configurationDigest == (try Digest.of(config)) else { throw ShouError("plan_stale", "Preview the draft again with the current configuration.") }
        let discovered=try installedCacheDiscovery(for: scan.workspace)
        let rules=try activeRules(config, workspaceId: scan.workspace.id, additionalBuiltins: discovered.rules)
        let tree=TreeSnapshot(entries: scan.entries, complete: scan.treeComplete ?? (scan.status == "complete"), issues: scan.issues, caseSensitive: scan.caseSensitive, completedPaths: scan.completedPaths)
        let blocked=try ApplicationSafety.blockedRules(rules.map(\.id), activity: applicationActivity).merging(
            InstalledApplicationCaches.blocked(discovered.evidence, workspace: scan.workspace, activity: uninstallEvidence), uniquingKeysWith: { _, value in value })
        let baseline=try Analysis.candidates(tree: tree, workspace: scan.workspace, rules: rules, now: scan.createdAt, blockedRules: blocked,
            artifactEvidence: artifactEvidence, artifactHomeDirectory: homeDirectory, maxSeconds: (scan.budget ?? ScanBudget()).maxSeconds)
        func measured(_ candidates: [Candidate]) -> [String: Int64] {
            let paths=candidates.filter(\.eligible).map(\.relativePath)
            var objects=[String: Int64]()
            for entry in scan.entries where entry.kind != "symlink" && paths.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") }) {
                objects[entry.objectIdentityKey]=max(0, entry.allocatedBytes)
            }
            return objects
        }
        let draft=measured(scan.candidates), existing=measured(baseline)
        let matched=draft.values.reduce(0,+), covered=draft.filter { existing[$0.key] != nil }.values.reduce(0,+)
        return RulePreviewBenefits(eligibleMatchCount: scan.candidates.filter(\.eligible).count,
            blockedMatchCount: scan.candidates.filter { !$0.ruleIds.isEmpty && !$0.eligible }.count,
            matchedAllocatedBytesEstimate: matched, alreadyCoveredAllocatedBytesEstimate: covered, additionalAllocatedBytesEstimate: matched-covered)
    }
    public func createPlan(scanId: String, candidateIds: [String], action: String = "trash") throws -> CleanupPlan {
        guard ["trash", "permanent"].contains(action) else {
            throw ShouError("invalid_argument", "Cleanup action must be trash or permanent.")
        }
        guard !candidateIds.isEmpty, Set(candidateIds).count == candidateIds.count else { throw ShouError("invalid_argument", "Explicit, unique candidate IDs are required.") }
        let snapshot = try scanSnapshot(scanId)
        let budget=snapshot.budget ?? ScanBudget()
        try budget.validate()
        guard !snapshot.previewOnly else { throw ShouError("partial_result", "Draft previews cannot produce executable plans.") }
        let config = try configuration()
        guard try Digest.of(config) == snapshot.configurationDigest else { throw ShouError("plan_stale", "Configuration changed; scan again.") }
        let selectedRuleIds=snapshot.candidates.filter { candidateIds.contains($0.id) }.flatMap(\.ruleIds)
        let installedCaches=try InstalledApplicationCaches.selected(snapshot.installedApplicationCaches, ruleIds: selectedRuleIds)
        try revalidateInstalledCaches(installedCaches, workspace: snapshot.workspace)
        let eligibleRules = try activeRules(config, workspaceId: snapshot.workspace.id,
            additionalBuiltins: installedCaches.map { try InstalledApplicationCaches.rule($0, workspace: snapshot.workspace) })
        let blocked=try ApplicationSafety.blockedRules(eligibleRules.map(\.id), activity: applicationActivity).merging(
            InstalledApplicationCaches.blocked(installedCaches, workspace: snapshot.workspace, activity: uninstallEvidence), uniquingKeysWith: { _, value in value })
        let reviewed = try Analysis.candidates(tree: TreeSnapshot(entries: snapshot.entries, complete: snapshot.treeComplete ?? (snapshot.status == "complete"), issues: snapshot.issues, caseSensitive: snapshot.caseSensitive, completedPaths: snapshot.completedPaths), workspace: protectedWorkspace(snapshot.workspace, configuration: config), rules: eligibleRules, now: snapshot.createdAt, blockedRules: blocked, artifactEvidence: artifactEvidence, artifactHomeDirectory: homeDirectory, maxSeconds: budget.maxSeconds)
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
        plan.action=action
        plan.scanBudget=snapshot.budget
        plan.scanScope=snapshot.scope
        plan.installedApplicationCaches=installedCaches.isEmpty ? nil : installedCaches
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
              rootIdentityMatches(try filesystem.rootIdentity(plan.workspace.path), plan.workspace.identity) else { throw ShouError("plan_stale", "Plan expired or workspace/configuration changed; preview again.") }
        guard ["trash", "permanent"].contains(plan.action) else { throw ShouError("store_corrupt", "Cleanup plan contains an unsupported action.") }
        if plan.action == "trash" && !filesystem.supportsTrash {
            throw ShouError("capability_unavailable", filesystem.trashUnavailableReason ?? "System Trash is unavailable; no deletion fallback is permitted.")
        }
        let currentConfig = try configuration()
        guard let registered = currentConfig.workspaces.first(where: { $0.id == plan.workspace.id }),
              registered.path == plan.workspace.path else { throw ShouError("plan_stale", "Plan workspace does not match its registered binding.") }
        let workspace=protectedWorkspace(registered, configuration: currentConfig)
        guard workspace.exclusions == plan.workspace.exclusions else { throw ShouError("plan_stale", "Plan workspace does not match its registered binding.") }
        // Persisted plans are data, never authority. Reproduce policy from fresh
        // coverage; every selected subtree must be complete independently.
        progress(ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: plan.items.count, path: registered.path))
        let installedCaches=try InstalledApplicationCaches.selected(plan.installedApplicationCaches, ruleIds: plan.items.flatMap { $0.candidate.ruleIds })
        try revalidateInstalledCaches(installedCaches, workspace: workspace)
        let currentRules=try activeRules(currentConfig, workspaceId: registered.id,
            additionalBuiltins: installedCaches.map { try InstalledApplicationCaches.rule($0, workspace: workspace) })
        let budget=plan.scanBudget ?? ScanBudget()
        try budget.validate()
        var readRules=currentRules
        for item in plan.items { try PathPattern.validate(item.candidate.relativePath) }
        if plan.scanScope == .cleanup, plan.items.allSatisfy({ !$0.candidate.relativePath.contains("*") && !$0.candidate.relativePath.contains("?") }) {
            // Selected paths bound I/O, never policy. Re-scanning their siblings
            // could exhaust a budget that already measured these full targets.
            readRules=currentRules.compactMap { rule in
                let paths=plan.items.filter { $0.candidate.ruleIds.contains(rule.id) }.map(\.candidate.relativePath)
                guard !paths.isEmpty else { return nil }
                var copy=rule; copy.match.relativePatterns=paths; return copy
            }
        }
        let currentTree = try inspect(registered.path, rules: readRules, scope: plan.scanScope ?? .full, budget: budget, progress: { [itemCount=plan.items.count] update in
            progress(ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: itemCount, path: update.currentPath))
        })
        let currentEntries=Dictionary(uniqueKeysWithValues: currentTree.entries.map { ($0.path, $0) })
        let currentCandidates = try Analysis.candidates(tree: currentTree, workspace: workspace, rules: currentRules, now: now(), artifactEvidence: artifactEvidence, artifactHomeDirectory: homeDirectory, maxSeconds: budget.maxSeconds)
        for item in plan.items {
            progress(ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: plan.items.count, path: plan.workspace.path + "/" + item.candidate.relativePath))
            try PathPattern.validate(item.candidate.relativePath)
            guard currentCandidates.contains(where: { $0.relativePath == item.candidate.relativePath && $0.eligible && $0.manifestDigest == item.candidate.manifestDigest && $0.ruleVersions == item.candidate.ruleVersions }),
                  try Digest.of(item.manifest) == item.candidate.manifestDigest else { throw ShouError("plan_stale", "Current policy or full manifest no longer permits this target.") }
            try verify(path: plan.workspace.path + "/" + item.candidate.relativePath, manifest: item.manifest)
        }
        let items=plan.items.map {
            ItemReceipt(id: $0.id, originalPath: plan.workspace.path + "/" + $0.candidate.relativePath, relativePath: $0.candidate.relativePath, trashPath: nil, manifest: $0.manifest, state: "pending", allocatedBytesEstimate: $0.candidate.allocatedBytesEstimate, error: nil)
        }
        let receipt: ExecutionReceipt
        if plan.action == "permanent" {
            receipt=try PermanentExecution.run(planId: plan.id, workspace: plan.workspace, items: items, entryPoint: entryPoint,
                store: store, filesystem: filesystem, now: now(), progress: progress,
                didBegin: { receipt in
                    plan.executionId=receipt.id; plan.state="executing"
                    try save(plan, collection: "plans", id: plan.id)
                }, validateItem: { index, _ in
                    let item=plan.items[index]
                    let blocked=ApplicationSafety.blockedRules(item.candidate.ruleIds, activity: applicationActivity)
                    if let reason=blocked.values.sorted().first { return reason }
                    if let reason=try installedCacheBlock(for: item, evidence: installedCaches, workspace: workspace) { return reason }
                    let policy=ArtifactSafety.sourcePolicy(path: item.candidate.relativePath, manifest: item.manifest,
                        entries: currentEntries, workspace: workspace,
                        rules: currentRules.filter { item.candidate.ruleIds.contains($0.id) }, homeDirectory: homeDirectory, evidence: artifactEvidence)
                    guard policy.reasons.isEmpty else { throw ShouError("plan_stale", "Artifact ownership or build activity changed before cleanup.", details: ["reasons": policy.reasons.joined(separator: ",")]) }
                    return nil
                })
        } else {
            receipt=try TrashExecution.run(planId: plan.id, workspace: plan.workspace, items: items, entryPoint: entryPoint,
                store: store, filesystem: filesystem, now: now(), progress: progress,
                didBegin: { receipt in
                    plan.executionId=receipt.id; plan.state="executing"
                    try save(plan, collection: "plans", id: plan.id)
                }, validateItem: { index in
                    let item=plan.items[index]
                    let blocked=ApplicationSafety.blockedRules(item.candidate.ruleIds, activity: applicationActivity)
                    if let reason=blocked.values.sorted().first { return reason }
                    if let reason=try installedCacheBlock(for: item, evidence: installedCaches, workspace: workspace) { return reason }
                    let policy=ArtifactSafety.sourcePolicy(path: item.candidate.relativePath, manifest: item.manifest,
                        entries: currentEntries, workspace: workspace,
                        rules: currentRules.filter { item.candidate.ruleIds.contains($0.id) }, homeDirectory: homeDirectory, evidence: artifactEvidence)
                    guard policy.reasons.isEmpty else { throw ShouError("plan_stale", "Artifact ownership or build activity changed before cleanup.", details: ["reasons": policy.reasons.joined(separator: ",")]) }
                    return nil
                })
        }
        plan.state=receipt.state; try save(plan, collection: "plans", id: plan.id)
        return receipt
    }
    private func inspect(_ path: String, rules: [CleanupRule], scope: ScanScope, budget: ScanBudget, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> TreeSnapshot {
        if scope == .cleanup { return try filesystem.inspectCleanup(path, rules: rules, budget: budget, cancelled: { Task.isCancelled }, progress: progress) }
        return try filesystem.inspect(path, budget: budget, cancelled: { Task.isCancelled }, progress: progress)
    }
    private func builtinRules(for workspace: Workspace) throws -> [CleanupRule] { try BuiltinCatalog.rules(for: workspace, homeDirectory: homeDirectory, platform: filesystem.platform) }
    public func builtinRules(workspaceId: String) throws -> [CleanupRule] {
        let workspace=try workspace(workspaceId)
        return try builtinRules(for: workspace) + installedCacheDiscovery(for: workspace).rules
    }
    private func installedCacheDiscovery(for workspace: Workspace) throws -> InstalledApplicationCaches.Discovery {
        try InstalledApplicationCaches.discover(workspace: workspace, homeDirectory: homeDirectory, platform: filesystem.platform,
            catalog: applicationCatalog, staticRules: builtinRules(for: workspace))
    }
    private func revalidateInstalledCaches(_ evidence: [InstalledApplicationCacheEvidence], workspace: Workspace) throws {
        try InstalledApplicationCaches.revalidate(evidence, workspace: workspace, homeDirectory: homeDirectory, platform: filesystem.platform,
            catalog: applicationCatalog, staticRules: builtinRules(for: workspace))
    }
    private func installedCacheBlock(for item: PlanItem, evidence: [InstalledApplicationCacheEvidence], workspace: Workspace) throws -> String? {
        let selected=try InstalledApplicationCaches.selected(evidence, ruleIds: item.candidate.ruleIds)
        try revalidateInstalledCaches(selected, workspace: workspace)
        return try InstalledApplicationCaches.blocked(selected, workspace: workspace, activity: uninstallEvidence).values.sorted().first
    }
    private func activeRules(_ config: Configuration, workspaceId: String, additionalBuiltins: [CleanupRule] = []) throws -> [CleanupRule] {
        guard let workspace=config.workspaces.first(where: { $0.id == workspaceId }) else { throw ShouError("invalid_argument", "Unknown workspace.") }
        let builtins=try (builtinRules(for: workspace) + additionalBuiltins).filter { rule in
            !config.bindings.contains { $0.workspaceId == workspaceId && $0.ruleId == rule.id && !$0.enabled }
        }
        return try builtins + config.bindings.filter { $0.workspaceId == workspaceId && $0.enabled && !$0.ruleId.hasPrefix(BuiltinCatalog.prefix) }.map { binding in
            guard let record=config.rules.first(where: { $0.rule.id == binding.ruleId && $0.rule.version == binding.version }) else { throw ShouError("store_corrupt", "Enabled rule definition is missing.") }
            return record.rule
        }
    }
    private func verify(path: String, manifest: [FileEntry], trashReceipt: Bool = false) throws {
        let budget=ScanBudget(maxEntries: max(100_000, manifest.count + 1), maxSeconds: 180)
        let current = try trashReceipt ? filesystem.inspectTrashTarget(path, budget: budget, cancelled: { Task.isCancelled }) : filesystem.inspectStorageTarget(path, budget: budget, cancelled: { Task.isCancelled })
        guard current.complete, current.entries.count == manifest.count,
              zip(current.entries, manifest).allSatisfy({ observed, saved in
                  observed == saved || (trashReceipt && observed.matchesTrashRoot(as: saved))
              }) else { throw ShouError("plan_stale", "Target identity or full directory manifest changed.", details: ["path": path]) }
    }
    public func history() throws -> [ExecutionReceipt] { try store.ids("history").map { try history($0) }.sorted { $0.createdAt > $1.createdAt } }
    public func history(_ id: String) throws -> ExecutionReceipt { try ReceiptJournal.load(id, store: store) }
    public func followUps() throws -> [FollowUpReceipt] { try store.ids("followups").map { try load(FollowUpReceipt.self, collection: "followups", id: $0) } }
    public func inspectHistory(executionId: String, budget: ScanBudget = ScanBudget()) throws -> HistoryInspection {
        // The mutation lease proves another Shou operation cannot still be
        // updating these paths. Inspection never rewrites receipts or retries it.
        let lease=try store.lock(); defer { lease.release() }
        return try HistoryInspector.inspect(history(executionId), followUps: followUps(), filesystem: filesystem, homeDirectory: homeDirectory, budget: budget, checkedAt: now())
    }
    public func followUpDigest(executionId: String, itemIds: [String], action: String) throws -> String {
        guard ["restore", "purge"].contains(action), !itemIds.isEmpty, Set(itemIds).count == itemIds.count else { throw ShouError("invalid_argument", "Select explicit receipt items and a supported action.") }
        let receipt = try history(executionId)
        guard !["application_permanent_uninstall", "application_batch_permanent_uninstall"].contains(receipt.operation ?? "") else {
            throw ShouError("capability_unavailable", "Permanently removed application components cannot be restored.")
        }
        guard !["application_uninstall", "application_batch_uninstall"].contains(receipt.operation ?? "") || action == "restore" else {
            throw ShouError("capability_unavailable", "Application uninstall receipts currently support restoration only.")
        }
        guard itemIds.allSatisfy({ id in receipt.items.contains { $0.id == id && $0.state == "trashed" } }) else { throw ShouError("invalid_argument", "Only verified trashed items can be restored or permanently removed.") }
        guard try !followUps().contains(where: { $0.executionId == executionId && itemIds.contains($0.itemId) && ["completed", "pending"].contains($0.state) }) else {
            throw ShouError("already_executed", "Receipt item already has a follow-up operation.")
        }
        return try Digest.of(JSONValue.object(["receipt": try .from(receipt), "items": .array(itemIds.sorted().map(JSONValue.string)), "action": .string(action)]))
    }
    public func followUp(executionId: String, itemIds: [String], action: String, confirmedDigest: String, progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> [FollowUpReceipt] {
        let lease = try store.lock(); defer { lease.release() }
        guard try followUpDigest(executionId: executionId, itemIds: itemIds, action: action) == confirmedDigest else { throw ShouError("confirmation_required", "Follow-up confirmation does not match.") }
        let receipt = try history(executionId)
        let existing = try followUps()
        let selectedIds=Set(itemIds)
        let items=receipt.items.filter { selectedIds.contains($0.id) }
        var results: [FollowUpReceipt] = []
        var removalContext=PermanentRemovalContext()
        progress(ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: items.count, path: receipt.workspace.path))
        for item in items {
            if Task.isCancelled { break }
            guard !existing.contains(where: { $0.executionId == executionId && $0.itemId == item.id && ($0.state == "completed" || $0.state == "pending") }), let trashPath = item.trashPath else { throw ShouError("already_executed", "Receipt item already has a follow-up operation.") }
            let origin=try ReceiptOrigins.resolve(receipt: receipt, item: item, homeDirectory: homeDirectory)
            guard filesystem.isTrashLocation(trashPath) else {
                throw ShouError("store_corrupt", "Receipt paths do not identify a workspace item and a system Trash location.")
            }
            var result = FollowUpReceipt(id: Codec.id("followup"), executionId: executionId, itemId: item.id, action: action, createdAt: now(), state: "pending", resultingPath: nil, error: nil)
            progress(ExecutionProgress(stage: "preflight", processedCount: results.count, itemCount: items.count, path: trashPath))
            do {
                try verify(path: trashPath, manifest: action == "purge" ? removalContext.reconciled(item.manifest) : item.manifest, trashReceipt: true)
                if action == "restore" {
                    guard try ReceiptOrigins.identity(origin, filesystem: filesystem).sameObject(as: origin.identity) else { throw ShouError("access_expired", "Original workspace identity changed.") }
                }
            }
            catch { if Task.isCancelled { break }; throw error }
            if Task.isCancelled { break }
            try save(result, collection: "followups", id: result.id)
            let stage=action == "restore" ? "restoring" : "purging"
            let path=action == "restore" ? item.originalPath : trashPath
            progress(ExecutionProgress(stage: stage, processedCount: results.count, itemCount: items.count, path: path))
            do {
                if action == "restore" {
                    try filesystem.restore(trashPath, to: item.originalPath, expected: item.manifest); result.resultingPath=item.originalPath
                } else {
                    try filesystem.purge(trashPath, expected: item.manifest, context: &removalContext, progress: { completed, total, current in
                        progress(ExecutionProgress(stage: "purging", processedCount: results.count, itemCount: items.count, path: current,
                            currentItemProcessedCount: completed, currentItemCount: total))
                    })
                }
                result.state="completed"
            } catch {
                // An uncertain native move retains its durable intent, which
                // blocks replay until read-only history inspection resolves it.
                result.state=["restore_outcome_unknown", "purge_outcome_unknown"].contains((error as? ShouError)?.code ?? "") ? "pending" : "failed"
                result.resultingPath=(error as? ShouError)?.details["resulting_path"]
                result.error=TrashExecution.diagnostic(error)
            }
            try save(result, collection: "followups", id: result.id); results.append(result)
            progress(ExecutionProgress(stage: stage, processedCount: results.count, itemCount: items.count, path: path))
        }
        return results
    }
    public func savePreset(name: String, workspaceId: String, ruleIds: [String]) throws -> Preset {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !ruleIds.isEmpty else { throw ShouError("invalid_argument", "A preset requires a name and explicit rules.") }
        let lease = try store.lock(); defer { lease.release() }
        var config = try configuration()
        let workspace=try workspace(workspaceId)
        let enabled=try activeRules(config, workspaceId: workspaceId, additionalBuiltins: installedCacheDiscovery(for: workspace).rules)
        guard ruleIds.allSatisfy({ id in enabled.contains { $0.id == id } }) else { throw ShouError("invalid_argument", "Preset rules must be enabled in this workspace.") }
        let preset = Preset(id: Codec.id("preset"), name: name, workspaceId: workspaceId, ruleIds: Array(Set(ruleIds)).sorted())
        config.presets.append(preset); try saveConfiguration(config); return preset
    }
}
