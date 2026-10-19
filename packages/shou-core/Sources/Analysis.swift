import Foundation

public enum Analysis {
    public static func subtree(_ entries: [FileEntry], path: String) -> [FileEntry] {
        subtreeSorted(entries.sorted { $0.path < $1.path }, path: path)
    }
    private static func subtreeSorted(_ entries: [FileEntry], path: String) -> [FileEntry] {
        let prefix = path + "/"
        func lowerBound(_ key: String) -> Int {
            var low=0, high=entries.count
            while low < high { let mid=(low+high)/2; if entries[mid].path < key { low=mid+1 } else { high=mid } }
            return low
        }
        var selected: [FileEntry]=[]
        let root=lowerBound(path)
        if root < entries.count && entries[root].path == path { selected.append(entries[root]) }
        var index=lowerBound(prefix)
        while index < entries.count && entries[index].path.hasPrefix(prefix) { selected.append(entries[index]); index += 1 }
        return selected.map { entry in
            var copy = entry
            copy.path = entry.path == path ? "." : String(entry.path.dropFirst(prefix.count))
            return copy
        }.sorted { $0.path < $1.path }
    }

    public static func candidates(tree: TreeSnapshot, workspace: Workspace, rules: [CleanupRule], now: Date, blockedRules: [String: String] = [:],
                                  artifactEvidence: any ArtifactEvidenceChecking = UnavailableArtifactEvidence(), artifactHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, maxSeconds: TimeInterval = 60) throws -> [Candidate] {
        try ScanBudget(maxSeconds: maxSeconds).validate()
        let deadline=ProcessInfo.processInfo.systemUptime + maxSeconds
        var byPath: [String: FileEntry]=[:]
        for entry in tree.entries {
            guard byPath.updateValue(entry, forKey: entry.path) == nil else { throw ShouError("store_corrupt", "Snapshot contains duplicate or ambiguous paths.") }
        }
        let ordered = tree.entries.sorted { $0.path < $1.path }
        let storage = StorageIndex(entries: tree.entries)
        let maxDepth = max(8, rules.map(\.scope.maxDepth).max() ?? 8)
        let prepared=rules.map { rule in (rule, rule.match.relativePatterns.map { PathPattern.Compiled($0, caseSensitive: tree.caseSensitive) }) }
        var result: [Candidate] = []
        var claimedBuiltinPaths=Set<String>()
        let evidence=AnalysisArtifactEvidence(base: artifactEvidence)
        for directory in ordered where directory.kind == "directory" && directory.path != "." {
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ShouError("resource_limit", "Candidate analysis exceeded its time budget.") }
            let path = directory.path
            let pathParts=path.split(separator: "/").map(String.init)
            guard pathParts.count <= maxDepth else { continue }
            let matchParts=tree.caseSensitive ? pathParts : pathParts.map { $0.lowercased() }
            guard let measured=storage.nodes[path] else { continue }
            let newest=measured.newestModifiedNanoseconds
            var logical=measured.logicalBytes, allocated=measured.allocatedBytes
            var matches: [CleanupRule] = []
            for (rule, patterns) in prepared {
                guard rule.scope.rootRef == workspace.rootRef,
                      pathParts.count <= rule.scope.maxDepth,
                      patterns.contains(where: { $0.matches(matchParts) }),
                      allocated >= rule.conditions.minAllocatedBytes else { continue }
                let parent = path.split(separator: "/").dropLast().joined(separator: "/")
                let markers = rule.match.projectMarkers?.allOf ?? []
                guard markers.allSatisfy({ byPath[parent.isEmpty ? $0 : parent + "/" + $0]?.kind == "file" }) else { continue }
                if let days = rule.conditions.newestDescendantModifiedDaysAtLeast,
                   now.timeIntervalSince1970 - Double(newest) / 1_000_000_000 < Double(days) * 86_400 { continue }
                matches.append(rule)
            }
            var parent=StorageIndex.parent(path), nestedBuiltin=false
            while parent != "." {
                if claimedBuiltinPaths.contains(parent) { nestedBuiltin=true; break }
                parent=StorageIndex.parent(parent)
            }
            if nestedBuiltin { matches.removeAll { $0.id.hasPrefix(BuiltinCatalog.prefix) } }
            if matches.contains(where: { $0.id.hasPrefix(BuiltinCatalog.prefix) }) { claimedBuiltinPaths.insert(path) }
            // Unclassified directories support navigation, but cannot authorize
            // mutation. Only matched targets need a serialized subtree manifest.
            if matches.isEmpty {
                result.append(Candidate(id: Codec.id("candidate"), relativePath: path, logicalBytes: logical,
                    allocatedBytesEstimate: allocated, newestModifiedAt: Date(timeIntervalSince1970: Double(newest) / 1_000_000_000),
                    manifestDigest: "", ruleIds: [], ruleVersions: [:], risk: "review",
                    reasons: tree.complete ? ["unclassified"] : ["unclassified", "incomplete_scan"], rebuildNotes: [], limitations: [], eligible: false))
                continue
            }
            if !tree.isComplete(at: path) {
                result.append(Candidate(id: Codec.id("candidate"), relativePath: path, logicalBytes: logical,
                    allocatedBytesEstimate: allocated, newestModifiedAt: Date(timeIntervalSince1970: Double(newest) / 1_000_000_000),
                    manifestDigest: "", ruleIds: matches.map(\.id).sorted(), ruleVersions: Dictionary(uniqueKeysWithValues: matches.map { ($0.id,$0.version) }),
                    risk: matches.contains { $0.risk.declaredLevel == "high" } ? "high" : "review", reasons: ["incomplete_scan"], rebuildNotes: matches.map(\.risk.rebuildNote), limitations: matches.flatMap(\.risk.limitations), eligible: false))
                continue
            }
            let manifest = subtreeSorted(ordered, path: path)
            var identities=Set<String>(); logical=0; allocated=0
            for entry in manifest where entry.kind != "symlink" && identities.insert("\(entry.device):\(entry.inode)").inserted {
                logical += max(0, entry.logicalBytes); allocated += max(0, entry.allocatedBytes)
            }
            let exclusions = workspace.exclusions + matches.flatMap(\.exclude.relativePatterns)
            var reasons=Set(matches.compactMap { blockedRules[$0.id] }).sorted()
            if (workspace.protectedRelativePaths ?? []).contains(where: { protected in
                if protected == "." { return true }
                let a=tree.caseSensitive ? path : path.lowercased()
                let b=tree.caseSensitive ? protected : protected.lowercased()
                return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
            }) { reasons.append("protected_content") }
            if manifest.contains(where: { $0.owner != workspace.identity.owner }) { reasons.append("protected_content") }
            let dependency = path.split(separator: "/").last == "node_modules" && matches.contains { $0.risk.declaredLevel == "high" }
            for entry in manifest {
                let full = entry.path == "." ? path : path + "/" + entry.path
                if exclusions.contains(where: { PathPattern.matches($0, full, caseSensitive: tree.caseSensitive) }) { reasons.append("excluded_descendant"); break }
            }
            let artifactPolicy=ArtifactSafety.sourcePolicy(path: path, manifest: manifest, entries: byPath, workspace: workspace,
                rules: matches, homeDirectory: artifactHomeDirectory, evidence: evidence)
            reasons.append(contentsOf: artifactPolicy.reasons)
            if manifest.contains(where: { protected($0, candidatePath: path, dependency: dependency, allowedSources: artifactPolicy.allowedPaths) }) { reasons.append("protected_content") }
            if matches.isEmpty { reasons.append("unclassified") }
            let eligible = reasons.isEmpty && !matches.isEmpty
            result.append(Candidate(id: Codec.id("candidate"), relativePath: path, logicalBytes: logical,
                allocatedBytesEstimate: allocated, newestModifiedAt: Date(timeIntervalSince1970: Double(newest) / 1_000_000_000),
                manifestDigest: eligible ? try Digest.of(manifest) : "", ruleIds: matches.map(\.id).sorted(),
                ruleVersions: Dictionary(uniqueKeysWithValues: matches.map { ($0.id, $0.version) }),
                risk: reasons.contains("protected_content") || reasons.contains("excluded_descendant") ? "blocked" : path.split(separator: "/").contains("node_modules") || matches.contains { $0.risk.declaredLevel == "high" } ? "high" : "review",
                reasons: reasons, rebuildNotes: matches.map(\.risk.rebuildNote), limitations: matches.flatMap(\.risk.limitations), eligible: eligible))
        }
        return result.sorted { $0.allocatedBytesEstimate == $1.allocatedBytesEstimate ? $0.relativePath < $1.relativePath : $0.allocatedBytesEstimate > $1.allocatedBytesEstimate }
    }

    private static func protected(_ entry: FileEntry, candidatePath: String, dependency: Bool, allowedSources: Set<String>) -> Bool {
        let full = entry.path == "." ? candidatePath : candidatePath + "/" + entry.path
        let parts = full.split(separator: "/").map(String.init)
        let protectedNames: Set<String> = [".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".shou", "keychains"]
        if parts.contains(where: { protectedNames.contains($0.lowercased()) }) { return true }
        if entry.kind == "symlink" { return false }
        if entry.kind != "file" && entry.kind != "directory" { return true }
        let name = parts.last ?? ""
        let lowerName=name.lowercased()
        if lowerName == ".env" || lowerName.hasPrefix(".env.") || lowerName.hasSuffix("-keypair.json") || [".npmrc", ".pypirc", ".netrc"].contains(lowerName) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["db", "sqlite", "sqlite3", "key", "pem", "p12", "pfx", "keychain", "keychain-db", "vmdk", "qcow2", "vdi", "vhdx"].contains(ext) { return true }
        if !dependency && !allowedSources.contains(entry.path) {
            if ["Cargo.toml", "Cargo.lock", "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Package.swift"].contains(name) { return true }
            if entry.kind == "file" && ["swift", "rs", "c", "cpp", "h", "py", "tsx", "jsx"].contains(ext) { return true }
        }
        return false
    }
}

/// A process inventory is shared only within this read-only analysis. Execution
/// uses fresh platform facts immediately before each move.
private final class AnalysisArtifactEvidence: ArtifactEvidenceChecking, @unchecked Sendable {
    private let base: any ArtifactEvidenceChecking
    private let deadline=Date().addingTimeInterval(12)
    private let lock=NSLock()
    private var processes: [Set<String>: Result<Set<String>, Error>]=[:]
    private struct Project: Hashable { let names: Set<String>; let path: String }
    private var projectProcesses: [Project: Result<Set<String>, Error>]=[:]
    init(base: any ArtifactEvidenceChecking) { self.base=base }
    private func checkBudget() throws {
        guard Date() < deadline else { throw ShouError("artifact_evidence_unavailable", "Some artifact checks reached their time limit. Unverified items remain protected.") }
    }
    func hasGitTrackedFiles(at path: String) throws -> Bool {
        try checkBudget(); return try base.hasGitTrackedFiles(at: path)
    }
    func cargoSourceIntegrity(at path: String, expected: [FileEntry]) throws -> CargoSourceIntegrity {
        try checkBudget(); return try base.cargoSourceIntegrity(at: path, expected: expected)
    }
    func runningBuildProcesses(in names: Set<String>) throws -> Set<String> {
        try checkBudget()
        lock.lock(); defer { lock.unlock() }
        if let cached=processes[names] { return try cached.get() }
        let result=Result { try base.runningBuildProcesses(in: names) }
        processes[names]=result; return try result.get()
    }
    func runningBuildProcesses(in names: Set<String>, affecting projectPath: String) throws -> Set<String> {
        try checkBudget()
        lock.lock(); defer { lock.unlock() }
        let key=Project(names: names, path: projectPath)
        if let cached=projectProcesses[key] { return try cached.get() }
        let result=Result { try base.runningBuildProcesses(in: names, affecting: projectPath) }
        projectProcesses[key]=result; return try result.get()
    }
}
