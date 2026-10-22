import Foundation
import ShouCore
import ShouPlatform

/// Supplies explicit platform facts without observing the user's projects or processes.
struct ArtifactFixtureEvidence: ArtifactEvidenceChecking {
    var tracked=false
    var active=Set<String>()
    var integrity=CargoSourceIntegrity.verified
    var integrityByPath: [String: CargoSourceIntegrity]=[:]
    var unavailable=false
    var cargoFailure: String?=nil

    func hasGitTrackedFiles(at path: String) throws -> Bool {
        if unavailable { throw ShouError("artifact_evidence_unavailable", "Fixture evidence is unavailable.") }
        return tracked
    }
    func cargoSourceIntegrity(at path: String, expected: [FileEntry]) throws -> CargoSourceIntegrity {
        if let cargoFailure { throw ShouError(cargoFailure, "Fixture archive evidence is unavailable.") }
        return integrityByPath[path] ?? integrity
    }
    func runningBuildProcesses(in names: Set<String>) throws -> Set<String> {
        if unavailable { throw ShouError("artifact_evidence_unavailable", "Fixture evidence is unavailable.") }
        return active.intersection(names)
    }
}

private struct ScopedArtifactFixtureEvidence: ArtifactEvidenceChecking {
    var projects: [String: Set<String>]
    func hasGitTrackedFiles(at path: String) throws -> Bool { false }
    func cargoSourceIntegrity(at path: String, expected: [FileEntry]) throws -> CargoSourceIntegrity { .verified }
    func runningBuildProcesses(in names: Set<String>) throws -> Set<String> {
        names.intersection(projects.values.reduce(into: Set<String>()) { $0.formUnion($1) })
    }
    func runningBuildProcesses(in names: Set<String>, affecting projectPath: String) throws -> Set<String> {
        names.intersection(projects[projectPath] ?? [])
    }
}

private enum ArtifactFactChange: CaseIterable, Sendable {
    case buildStarted
    case trackedFileAppeared

    var reason: String { self == .buildStarted ? "build_process_running" : "tracked_artifact_content" }
}

private final class ChangingArtifactFixtureEvidence: ArtifactEvidenceChecking, @unchecked Sendable {
    private let lock=NSLock()
    private var changed=false
    let change: ArtifactFactChange
    init(_ change: ArtifactFactChange) { self.change=change }
    func activate() { lock.lock(); defer { lock.unlock() }; changed=true }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return changed }
    func hasGitTrackedFiles(at path: String) throws -> Bool { isActive && change == .trackedFileAppeared }
    func cargoSourceIntegrity(at path: String, expected: [FileEntry]) throws -> CargoSourceIntegrity { .verified }
    func runningBuildProcesses(in names: Set<String>) throws -> Set<String> {
        isActive && change == .buildStarted ? names.intersection(["cargo"]) : []
    }
}

/// A platform event changes facts after the selected target's final manifest
/// inspection, without coupling the fixture to the number of policy checks.
private final class ArtifactVerificationEventFileSystem: PlatformFileSystem, @unchecked Sendable {
    private let wrapped: FixtureFileSystem
    private let target: String
    private let afterInspection: @Sendable () -> Void
    private let lock=NSLock()
    private var attemptedMoves=0
    init(wrapped: FixtureFileSystem, target: String, afterInspection: @escaping @Sendable () -> Void) {
        self.wrapped=wrapped; self.target=target; self.afterInspection=afterInspection
    }
    var moveAttempts: Int { lock.lock(); defer { lock.unlock() }; return attemptedMoves }
    var platform: String { wrapped.platform }
    var supportsTrash: Bool { wrapped.supportsTrash }
    func rootIdentity(_ path: String) throws -> FileEntry { try wrapped.rootIdentity(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        let result=try wrapped.inspect(path, budget: budget, cancelled: cancelled)
        if path == target { afterInspection() }
        return result
    }
    func availableBytes(_ path: String) -> Int64? { wrapped.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { wrapped.isTrashLocation(path) }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult {
        lock.lock(); attemptedMoves += 1; lock.unlock()
        return try wrapped.moveToTrash(path, expected: expected)
    }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws {
        try wrapped.restore(path, to: destination, expected: expected)
    }
    func purge(_ path: String, expected: [FileEntry]) throws { try wrapped.purge(path, expected: expected) }
}

private func artifactWorkspace(_ fixture: Fixture, relativePath: String? = nil, rootRef: String = "artifact-workspace") async throws -> Workspace {
    let engine=ShouEngine(store: fixture.store, filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash))
    let path=relativePath.map { fixture.workspace.appendingPathComponent($0).path } ?? fixture.workspace.path
    return try await engine.addWorkspace(path: path, rootRef: rootRef)
}

private func artifactRule(_ id: String, workspace: Workspace) throws -> CleanupRule {
    try require(BuiltinCatalog.templates().first { $0.id == id }).rule(rootRef: workspace.rootRef)
}

private func artifactTree(_ fixture: Fixture, workspace: Workspace) throws -> TreeSnapshot {
    try fixture.fs.inspect(workspace.path, budget: ScanBudget(), cancelled: { false })
}

private func artifactCandidate(_ path: String, tree: TreeSnapshot, workspace: Workspace, rules: [CleanupRule],
                               evidence: any ArtifactEvidenceChecking = ArtifactFixtureEvidence(), homeDirectory: URL) throws -> Candidate {
    try require(Analysis.candidates(tree: tree, workspace: workspace, rules: rules, now: Date(),
        artifactEvidence: evidence, artifactHomeDirectory: homeDirectory).first { $0.relativePath == path })
}

private func addGeneratedRustFixture(_ fixture: Fixture) throws {
    try fixture.put("project/target/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55")
    try fixture.put("project/target/.rustc_info.json", "{}")
    try fixture.put("project/target/debug/.fingerprint/example-0123456789abcdef/lib-example", "fixture")
    try fixture.put("project/target/debug/build/example-0123456789abcdef/out/bindings.rs", "pub const GENERATED: u8 = 1;")
}

func generatedRustSourcesRequireTrustedRulesAndFacts() async throws {
    let fixture=try Fixture()
    try addGeneratedRustFixture(fixture)
    let workspace=try await artifactWorkspace(fixture)
    let rule=try artifactRule("shou.builtin.rust-target", workspace: workspace)
    let tree=try artifactTree(fixture, workspace: workspace)
    let candidate=try artifactCandidate("project/target", tree: tree, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
    try expect(candidate.eligible && candidate.risk == "high" && candidate.ruleVersions[rule.id] == "1.1.0")
    try expect(!candidate.manifestDigest.isEmpty)
    let strict=try artifactCandidate("project/target", tree: tree, workspace: workspace, rules: [rule],
        evidence: UnavailableArtifactEvidence(), homeDirectory: fixture.workspace)
    try expect(!strict.eligible && strict.reasons.contains("artifact_evidence_unavailable"))

    var custom=rule
    custom.id="personal.rust-target"
    let personal=try artifactCandidate("project/target", tree: tree, workspace: workspace, rules: [custom], homeDirectory: fixture.workspace)
    try expect(!personal.eligible && personal.reasons.contains("protected_content"))
    var impersonated=rule
    impersonated.risk.rebuildNote="A locally modified rule cannot gain built-in privileges."
    let modified=try artifactCandidate("project/target", tree: tree, workspace: workspace, rules: [impersonated], homeDirectory: fixture.workspace)
    try expect(!modified.eligible && modified.reasons.contains("protected_content"))
}

func generatedRustSourcesPreserveAuthoredFilesAndRequireLayout() async throws {
    let fixture=try Fixture()
    try addGeneratedRustFixture(fixture)
    let workspace=try await artifactWorkspace(fixture)
    let rule=try artifactRule("shou.builtin.rust-target", workspace: workspace)
    let tree=try artifactTree(fixture, workspace: workspace)
    for missing in ["project/target/CACHEDIR.TAG", "project/target/.rustc_info.json", "project/target/debug/.fingerprint"] {
        var incompleteLayout=tree
        incompleteLayout.entries.removeAll { $0.path == missing || $0.path.hasPrefix(missing + "/") }
        let candidate=try artifactCandidate("project/target", tree: incompleteLayout, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
        try expect(!candidate.eligible)
    }
    for authored in ["handwritten.rs", "manual/handwritten.rs", "debug/build/example-0123456789abcdef/out/Cargo.toml",
                     "debug/build/example-0123456789abcdef/out/package-lock.json", "debug/build/example-0123456789abcdef/out/pnpm-lock.yaml",
                     "debug/build/example-0123456789abcdef/out/yarn.lock"] {
        var changed=tree
        var source=try require(tree.entries.first { $0.path.hasSuffix("/bindings.rs") })
        source.path="project/target/" + authored
        source.inode += 1_000
        changed.entries.append(source)
        let candidate=try artifactCandidate("project/target", tree: changed, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
        try expect(!candidate.eligible && candidate.reasons.contains("protected_content"))
    }
}

func generatedArtifactsBlockTrackedContentActiveBuildsAndUnknownFacts() async throws {
    let fixture=try Fixture()
    try addGeneratedRustFixture(fixture)
    let workspace=try await artifactWorkspace(fixture)
    let rule=try artifactRule("shou.builtin.rust-target", workspace: workspace)
    let tree=try artifactTree(fixture, workspace: workspace)
    let cases: [(ArtifactFixtureEvidence, String)]=[
        (.init(tracked: true), "tracked_artifact_content"),
        (.init(active: ["cargo"]), "build_process_running"),
        (.init(active: ["rust-analyzer"]), "build_process_running"),
        (.init(unavailable: true), "artifact_evidence_unavailable")
    ]
    for (evidence, reason) in cases {
        let candidate=try artifactCandidate("project/target", tree: tree, workspace: workspace, rules: [rule], evidence: evidence, homeDirectory: fixture.workspace)
        try expect(!candidate.eligible && candidate.reasons.contains(reason))
    }
}

func generatedArtifactExceptionsNeverBypassHardProtections() async throws {
    let fixture=try Fixture()
    try addGeneratedRustFixture(fixture)
    let workspace=try await artifactWorkspace(fixture)
    let rule=try artifactRule("shou.builtin.rust-target", workspace: workspace)
    let tree=try artifactTree(fixture, workspace: workspace)
    for forbidden in [".ENV.local", ".npmrc", ".pypirc", ".netrc", ".GIT/config", ".ssh/config", "wallet-keypair.json", "state.sqlite3", "private.pem"] {
        var changed=tree
        var entry=try require(tree.entries.first { $0.path.hasSuffix("/bindings.rs") })
        entry.path="project/target/debug/build/example-0123456789abcdef/out/" + forbidden
        entry.inode += 1_000
        changed.entries.append(entry)
        let candidate=try artifactCandidate("project/target", tree: changed, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
        try expect(!candidate.eligible && candidate.reasons.contains("protected_content"))
    }
}

func generatedSwiftSourcesStayInsideVerifiedProducts() async throws {
    let fixture=try Fixture()
    let product="swift/.build/arm64-apple-macosx/debug"
    try fixture.put("swift/Package.swift", "// swift-tools-version: 6.0")
    try fixture.put("swift/.build/workspace-state.json", "{}")
    try fixture.put(product + "/description.json", "{}")
    try fixture.put(product + "/Demo.build/DerivedSources/resource_bundle_accessor.swift", "// generated")
    try fixture.put(product + "/DemoPackageDiscoveredTests.derived/all-discovered-tests.swift", "// generated")
    try fixture.put("swift/.build/checkouts/dependency/Sources/Keep.swift", "// authored dependency")
    let workspace=try await artifactWorkspace(fixture)
    let rule=try artifactRule("shou.builtin.swift-build", workspace: workspace)
    let tree=try artifactTree(fixture, workspace: workspace)
    let candidate=try artifactCandidate(product, tree: tree, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
    try expect(candidate.eligible && candidate.risk == "high" && candidate.ruleVersions[rule.id] == "1.1.0")
    let all=try Analysis.candidates(tree: tree, workspace: workspace, rules: [rule], now: Date(),
        artifactEvidence: ArtifactFixtureEvidence(), artifactHomeDirectory: fixture.workspace)
    try expect(all.filter(\.eligible).allSatisfy { !$0.relativePath.contains("/checkouts") && !$0.relativePath.hasSuffix("/.build") })

    for missing in ["swift/Package.swift", "swift/.build/workspace-state.json", product + "/description.json"] {
        var missingEvidence=tree
        missingEvidence.entries.removeAll { $0.path == missing }
        let blocked=try artifactCandidate(product, tree: missingEvidence, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
        try expect(!blocked.eligible && blocked.reasons.contains("artifact_layout_unverified"))
    }
    for authored in ["Sources/Keep.swift", "manual.swift", "Demo.build/DerivedSources/Package.swift"] {
        var changed=tree
        var source=try require(tree.entries.first { $0.path.hasSuffix("resource_bundle_accessor.swift") })
        source.path=product + "/" + authored
        source.inode += 1_000
        changed.entries.append(source)
        let blocked=try artifactCandidate(product, tree: changed, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
        try expect(!blocked.eligible && blocked.reasons.contains("protected_content"))
    }
    let running=try artifactCandidate(product, tree: tree, workspace: workspace, rules: [rule],
        evidence: ArtifactFixtureEvidence(active: ["swift-frontend"]), homeDirectory: fixture.workspace)
    try expect(!running.eligible && running.reasons.contains("build_process_running"))
}

func extractedCargoSourcesRequirePerCrateEvidenceAndExactHome() async throws {
    let fixture=try Fixture()
    let registry="registry/src/index.crates.io-0123456789abcdef"
    let good=registry + "/good-1.0.0", modified=registry + "/modified-1.0.0"
    for crate in [good, modified] {
        try fixture.put(".cargo/" + crate + "/Cargo.toml", "[package]")
        try fixture.put(".cargo/" + crate + "/.cargo-checksum.json", "{}")
        try fixture.put(".cargo/" + crate + "/src/lib.rs", "pub const FIXTURE: u8 = 1;")
    }
    let workspace=try await artifactWorkspace(fixture, relativePath: ".cargo")
    let rule=try artifactRule("shou.builtin.cargo-extracted-sources", workspace: workspace)
    let tree=try artifactTree(fixture, workspace: workspace)
    let facts=ArtifactFixtureEvidence(integrityByPath: [workspace.path + "/" + modified: .modified])
    let verified=try artifactCandidate(good, tree: tree, workspace: workspace, rules: [rule], evidence: facts, homeDirectory: fixture.workspace)
    let changed=try artifactCandidate(modified, tree: tree, workspace: workspace, rules: [rule], evidence: facts, homeDirectory: fixture.workspace)
    try expect(verified.eligible && verified.risk == "high")
    try expect(!changed.eligible && changed.reasons.contains("cargo_source_modified"))
    let wrongHome=try artifactCandidate(good, tree: tree, workspace: workspace, rules: [rule], homeDirectory: fixture.base)
    try expect(!wrongHome.eligible && wrongHome.reasons.contains("artifact_layout_unverified"))

    for code in ["artifact_restore_unavailable", "artifact_evidence_unavailable"] {
        let blocked=try artifactCandidate(good, tree: tree, workspace: workspace, rules: [rule],
            evidence: ArtifactFixtureEvidence(cargoFailure: code), homeDirectory: fixture.workspace)
        try expect(!blocked.eligible && blocked.reasons.contains(code))
    }
    let unavailable=try artifactCandidate(good, tree: tree, workspace: workspace, rules: [rule],
        evidence: UnavailableArtifactEvidence(), homeDirectory: fixture.workspace)
    try expect(!unavailable.eligible && unavailable.reasons.contains("artifact_evidence_unavailable"))
    var missingChecksum=tree
    missingChecksum.entries.removeAll { $0.path == good + "/.cargo-checksum.json" }
    let missing=try artifactCandidate(good, tree: missingChecksum, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
    try expect(!missing.eligible && missing.reasons.contains("artifact_layout_unverified"))

    var custom=rule
    custom.id="personal.extracted-cargo"
    let personal=try artifactCandidate(good, tree: tree, workspace: workspace, rules: [custom], homeDirectory: fixture.workspace)
    try expect(!personal.eligible && personal.reasons.contains("protected_content"))
}

func artifactFactsChangingImmediatelyBeforeMovePreserveFiles() async throws {
    for change in ArtifactFactChange.allCases {
        let fixture=try Fixture()
        try addGeneratedRustFixture(fixture)
        let target=fixture.workspace.appendingPathComponent("project/target").path
        let source=URL(fileURLWithPath: target).appendingPathComponent("debug/build/example-0123456789abcdef/out/bindings.rs")
        let sourceHash=Digest.sha256(try Data(contentsOf: source))
        let before=try fixture.fs.inspect(target, budget: ScanBudget(), cancelled: { false })
        let evidence=ChangingArtifactFixtureEvidence(change)
        let filesystem=ArtifactVerificationEventFileSystem(
            wrapped: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), target: target,
            afterInspection: { evidence.activate() })
        let engine=ShouEngine(store: fixture.store, filesystem: filesystem, artifactEvidence: evidence, homeDirectory: fixture.workspace)
        let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "artifact-execution")
        let scan=try await engine.scan(workspaceId: workspace.id)
        let candidate=try require(scan.candidates.first { $0.relativePath == "project/target" })
        try expect(candidate.eligible && candidate.risk == "high")
        let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
        try expect(!evidence.isActive && filesystem.moveAttempts == 0)

        // Fresh whole-workspace analysis sees valid facts. Only the subsequent
        // selected-target inspection starts a build or introduces Git ownership.
        let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
        let item=try require(receipt.items.first)
        try expect(evidence.isActive && filesystem.moveAttempts == 0)
        try expect(receipt.state == "partial" && item.state == "failed" && item.trashPath == nil)
        try expect(item.error?.contains(change.reason) == true)
        try expect(receipt.trashedBytesEstimate == 0)
        let after=try fixture.fs.inspect(target, budget: ScanBudget(), cancelled: { false })
        try expect(before.complete && after.complete && before.entries == after.entries)
        try expect(Digest.sha256(try Data(contentsOf: source)) == sourceHash)
        try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
        let saved=try await engine.history(receipt.id)
        try expect(saved.state == "partial" && saved.items.first?.state == "failed")
    }
}

func binaryOnlyRustTargetsStillRequireActivityAndOwnershipFacts() async throws {
    let fixture=try Fixture()
    let workspace=try await artifactWorkspace(fixture)
    let rule=try artifactRule("shou.builtin.rust-target", workspace: workspace)
    let tree=try artifactTree(fixture, workspace: workspace)
    let ready=try artifactCandidate("project/target", tree: tree, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
    try expect(ready.eligible)
    for (facts, reason) in [(ArtifactFixtureEvidence(active: ["cargo"]), "build_process_running"),
                            (ArtifactFixtureEvidence(tracked: true), "tracked_artifact_content")] {
        let candidate=try artifactCandidate("project/target", tree: tree, workspace: workspace, rules: [rule], evidence: facts, homeDirectory: fixture.workspace)
        try expect(!candidate.eligible && candidate.reasons.contains(reason))
    }
    let unavailable=try artifactCandidate("project/target", tree: tree, workspace: workspace, rules: [rule], evidence: UnavailableArtifactEvidence(), homeDirectory: fixture.workspace)
    try expect(!unavailable.eligible && unavailable.reasons.contains("artifact_evidence_unavailable"))
    // The shared legacy checker implements only the original global method;
    // protocol fallback must keep its conservative activity gate intact.
    try expect(try ArtifactFixtureEvidence(active: ["rust-analyzer"]).runningBuildProcesses(in: ["rust-analyzer"], affecting: workspace.path + "/project") == ["rust-analyzer"])
}

func projectScopedActivityDoesNotBlockUnrelatedRustOrSwiftProjects() async throws {
    let fixture=try Fixture()
    try addGeneratedRustFixture(fixture)
    let swiftProduct="swift/.build/debug"
    try fixture.put("swift/Package.swift", "// swift-tools-version: 6.0")
    try fixture.put("swift/.build/workspace-state.json", "{}")
    try fixture.put(swiftProduct + "/description.json", "{}")
    try fixture.put(swiftProduct + "/Demo.build/DerivedSources/generated.swift", "// generated")
    let workspace=try await artifactWorkspace(fixture)
    let tree=try artifactTree(fixture, workspace: workspace)
    let rust=try artifactRule("shou.builtin.rust-target", workspace: workspace)
    let swift=try artifactRule("shou.builtin.swift-build", workspace: workspace)
    let unrelated=ScopedArtifactFixtureEvidence(projects: [workspace.path + "/unrelated": ["rust-analyzer", "swift-frontend"]])
    for (path, rule, project, process) in [("project/target", rust, "project", "rust-analyzer"), (swiftProduct, swift, "swift", "swift-frontend")] {
        let permitted=try artifactCandidate(path, tree: tree, workspace: workspace, rules: [rule], evidence: unrelated, homeDirectory: fixture.workspace)
        try expect(permitted.eligible)
        let related=ScopedArtifactFixtureEvidence(projects: [workspace.path + "/" + project: [process]])
        let blocked=try artifactCandidate(path, tree: tree, workspace: workspace, rules: [rule], evidence: related, homeDirectory: fixture.workspace)
        try expect(!blocked.eligible && blocked.reasons.contains("build_process_running"))
    }
    // Registry sources are shared across projects and retain the global gate.
    let crate="registry/src/index.crates.io-0123456789abcdef/demo-1.0.0"
    try fixture.put(".cargo/" + crate + "/Cargo.toml", "[package]")
    try fixture.put(".cargo/" + crate + "/.cargo-checksum.json", "{}")
    let cargo=try await artifactWorkspace(fixture, relativePath: ".cargo", rootRef: "artifact-cargo-workspace")
    let cargoRule=try artifactRule("shou.builtin.cargo-extracted-sources", workspace: cargo)
    let blocked=try artifactCandidate(crate, tree: artifactTree(fixture, workspace: cargo), workspace: cargo, rules: [cargoRule], evidence: unrelated, homeDirectory: fixture.workspace)
    try expect(!blocked.eligible && blocked.reasons.contains("build_process_running"))
}

private struct GeneratedProjectFixture {
    let project: String
    let marker: String
    let output: String
    let source: String
    let rule: String
    let metadata: [String]
    let requiredMetadata: String?
    var target: String { project + "/" + output }
}

private func addGeneratedProjectFixtures(_ fixture: Fixture) throws -> [GeneratedProjectFixture] {
    let cases: [GeneratedProjectFixture]=[
        .init(project: "gradle", marker: "build.gradle", output: "build", source: "generated/sources/annotationProcessor/java/main/Demo.java", rule: "gradle-build", metadata: ["tmp/compile/state.bin", "classes/Demo.class"], requiredMetadata: "tmp"),
        .init(project: "kotlin", marker: "build.gradle.kts", output: "build", source: "generated/ksp/main/kotlin/Demo.kt", rule: "gradle-kotlin-build", metadata: ["tmp/compile/state.bin", "classes/Demo.class"], requiredMetadata: "tmp"),
        .init(project: "flutter-tools", marker: "pubspec.yaml", output: ".dart_tool", source: "flutter_build/0123456789abcdef/dart_plugin_registrant.dart", rule: "flutter-build", metadata: ["package_config.json"], requiredMetadata: "package_config.json"),
        .init(project: "flutter-web", marker: "pubspec.yaml", output: "build", source: "web/main.dart.js", rule: "flutter-build", metadata: ["web/version.json"], requiredMetadata: "web/version.json"),
        .init(project: "cmake", marker: "CMakeLists.txt", output: "cmake-build-release", source: "CMakeFiles/3.31.0/CompilerIdC/CMakeCCompilerId.c", rule: "cmake-build", metadata: ["CMakeCache.txt"], requiredMetadata: "CMakeCache.txt"),
        .init(project: "maven", marker: "pom.xml", output: "target", source: "generated-sources/annotations/Demo.java", rule: "maven-build", metadata: ["maven-status/compiler/inputs.lst"], requiredMetadata: "maven-status"),
        .init(project: "node-dist", marker: "package.json", output: "dist", source: "assets/app-abcdefgh.js", rule: "node-build-outputs", metadata: [], requiredMetadata: nil),
        .init(project: "next", marker: "package.json", output: ".next", source: "server/app/page.js", rule: "node-build-cache", metadata: ["build-manifest.json"], requiredMetadata: "build-manifest.json"),
        .init(project: "nuxt", marker: "package.json", output: ".nuxt", source: "types/generated.d.ts", rule: "node-build-cache", metadata: ["tsconfig.json", "nuxt.d.ts"], requiredMetadata: "tsconfig.json")
    ]
    for item in cases {
        try fixture.put(item.project + "/" + item.marker, "fixture project marker")
        try fixture.put(item.target + "/" + item.source, "fixture generated source")
        for metadata in item.metadata { try fixture.put(item.target + "/" + metadata, "fixture build metadata") }
    }
    return cases
}

func additionalProjectSourcesStayInsideVerifiedGeneratedLayouts() async throws {
    let fixture=try Fixture()
    let cases=try addGeneratedProjectFixtures(fixture)
    let workspace=try await artifactWorkspace(fixture)
    let tree=try artifactTree(fixture, workspace: workspace)
    for item in cases {
        let rule=try artifactRule("shou.builtin." + item.rule, workspace: workspace)
        let candidate=try artifactCandidate(item.target, tree: tree, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
        try expect(candidate.eligible && candidate.risk == rule.risk.declaredLevel && !candidate.manifestDigest.isEmpty)
        if let required=item.requiredMetadata {
            var incomplete=tree
            let missing=item.target + "/" + required
            incomplete.entries.removeAll { $0.path == missing || $0.path.hasPrefix(missing + "/") }
            let blocked=try artifactCandidate(item.target, tree: incomplete, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
            try expect(!blocked.eligible && blocked.reasons.contains("protected_content"))
        }
        var custom=rule
        custom.risk.rebuildNote += " Locally edited."
        let untrusted=try artifactCandidate(item.target, tree: tree, workspace: workspace, rules: [custom], homeDirectory: fixture.workspace)
        try expect(!untrusted.eligible && untrusted.reasons.contains("protected_content"))
    }
}

func additionalProjectArtifactsBlockAuthoredAndProtectedContent() async throws {
    let fixture=try Fixture()
    let cases=try addGeneratedProjectFixtures(fixture)
    let workspace=try await artifactWorkspace(fixture)
    let tree=try artifactTree(fixture, workspace: workspace)
    for item in cases {
        let rule=try artifactRule("shou.builtin." + item.rule, workspace: workspace)
        let original=try require(tree.entries.first { $0.path == item.target + "/" + item.source })
        let ext=(item.source as NSString).pathExtension
        let paths=["manual/Keep." + ext, "generated/manual/Keep." + ext, "nuxt.config.ts", "package.json", "GRADLE.PROPERTIES", "POM.XML",
                   ".git/config", ".ENV.local", ".aws/credentials", "private.pem", "state.sqlite3"]
        for path in paths {
            var changed=tree
            var entry=original
            entry.path=item.target + "/" + path
            entry.inode += 10_000
            changed.entries.append(entry)
            let blocked=try artifactCandidate(item.target, tree: changed, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
            try expect(!blocked.eligible && blocked.reasons.contains("protected_content"))
        }
    }
}

func projectArtifactActivityIsScopedAndUnknownFactsRemainBlocked() async throws {
    let fixture=try Fixture()
    let cases: [(String, String, String, String, String)]=[
        ("gradle", "build.gradle", "build/classes/Demo.class", "gradle-build", "java"),
        ("flutter", "pubspec.yaml", ".dart_tool/package_config.json", "flutter-build", "dart"),
        ("node", "package.json", "dist/artifact.bin", "node-build-outputs", "node"),
        ("python", "pyproject.toml", ".mypy_cache/state.json", "python-analysis-cache", "python3.12")
    ]
    for (project, marker, output, _, _) in cases {
        try fixture.put(project + "/" + marker)
        try fixture.put(project + "/" + output)
    }
    let workspace=try await artifactWorkspace(fixture)
    let tree=try artifactTree(fixture, workspace: workspace)
    for (project, _, output, id, process) in cases {
        let path=project + "/" + output.split(separator: "/")[0]
        let rule=try artifactRule("shou.builtin." + id, workspace: workspace)
        let unrelated=ScopedArtifactFixtureEvidence(projects: [workspace.path + "/another-project": [process]])
        let available=try artifactCandidate(path, tree: tree, workspace: workspace, rules: [rule], evidence: unrelated, homeDirectory: fixture.workspace)
        try expect(available.eligible)
        let related=ScopedArtifactFixtureEvidence(projects: [workspace.path + "/" + project: [process]])
        let running=try artifactCandidate(path, tree: tree, workspace: workspace, rules: [rule], evidence: related, homeDirectory: fixture.workspace)
        try expect(!running.eligible && running.reasons.contains("build_process_running"))
        for (evidence, reason) in [(ArtifactFixtureEvidence(tracked: true), "tracked_artifact_content"),
                                   (ArtifactFixtureEvidence(unavailable: true), "artifact_evidence_unavailable")] {
            let blocked=try artifactCandidate(path, tree: tree, workspace: workspace, rules: [rule], evidence: evidence, homeDirectory: fixture.workspace)
            try expect(!blocked.eligible && blocked.reasons.contains(reason))
        }
    }
}

func browserAutomationCachesRequireGlobalActivityFactsAndProtectSource() async throws {
    let fixture=try Fixture()
    try fixture.put("Library/Caches/ms-playwright/chromium/chrome", "fixture runtime binary")
    let workspace=try await artifactWorkspace(fixture, relativePath: "Library/Caches", rootRef: "browser-runtime-caches")
    let rule=try artifactRule("shou.builtin.browser-automation-caches", workspace: workspace)
    let tree=try artifactTree(fixture, workspace: workspace)
    let safe=try artifactCandidate("ms-playwright", tree: tree, workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
    try expect(safe.eligible && safe.risk == "high")
    for name in ["node", "playwright", "Cypress"] {
        let active=ScopedArtifactFixtureEvidence(projects: [fixture.workspace.path + "/unrelated-project": [name]])
        let blocked=try artifactCandidate("ms-playwright", tree: tree, workspace: workspace, rules: [rule], evidence: active, homeDirectory: fixture.workspace)
        try expect(!blocked.eligible && blocked.reasons.contains("build_process_running"))
    }
    let unavailable=try artifactCandidate("ms-playwright", tree: tree, workspace: workspace, rules: [rule], evidence: UnavailableArtifactEvidence(), homeDirectory: fixture.workspace)
    try expect(!unavailable.eligible && unavailable.reasons.contains("artifact_evidence_unavailable"))
    try fixture.put("Library/Caches/ms-playwright/custom/manual.js", "fixture authored source")
    let authored=try artifactCandidate("ms-playwright", tree: artifactTree(fixture, workspace: workspace), workspace: workspace, rules: [rule], homeDirectory: fixture.workspace)
    try expect(!authored.eligible && authored.reasons.contains("protected_content"))
}

func nativeBuildActivityScopesCurrentProcessToItsWorkingDirectory() throws {
    #if os(macOS)
    let fixture=try Fixture()
    let evidence=NativeArtifactEvidence()
    let ownName=URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    let related=try evidence.runningBuildProcesses(in: [ownName], affecting: FileManager.default.currentDirectoryPath)
    try expect(related.contains(ownName))
    let unrelated=try evidence.runningBuildProcesses(in: [ownName], affecting: fixture.workspace.path)
    try expect(unrelated.isEmpty)
    #endif
}
