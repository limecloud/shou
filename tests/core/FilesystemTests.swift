import Foundation
import ShouCore
import ShouPlatform
#if canImport(Darwin)
import Darwin
#endif

final class Fixture: @unchecked Sendable {
    let base: URL
    let workspace: URL
    let trash: URL
    let store: LocalRecordStore
    let fs=NativeFileSystem()
    init() throws {
        let temporary=FileManager.default.temporaryDirectory.path
        // Foundation may retain macOS's /var alias even after resolvingSymlinksInPath.
        let physical=temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
        base=URL(fileURLWithPath: physical).appendingPathComponent("shou-test-" + UUID().uuidString, isDirectory: true)
        workspace=base.appendingPathComponent("workspace", isDirectory: true)
        trash=base.appendingPathComponent("isolated-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        store=try LocalRecordStore(directory: base.appendingPathComponent("store"))
        try put("project/Cargo.toml", "[package]\nname = 'fixture'\n")
        try put("project/target/artifact.bin", String(repeating: "x", count: 8192))
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    func put(_ path: String, _ content: String = "fixture") throws {
        let url=workspace.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    func ready() async throws -> (ShouEngine, Workspace, ScanSnapshot, Candidate) {
        let engine=ShouEngine(store: store, filesystem: FixtureFileSystem(native: fs, trash: trash), artifactEvidence: ArtifactFixtureEvidence())
        let root=try await engine.addWorkspace(path: workspace.path, rootRef: "test-workspace")
        _ = try await engine.importRule(fixtureRule())
        _ = try await engine.setRule(ruleId: "test.artifacts", workspaceId: root.id, enabled: true)
        let scan=try await engine.scan(workspaceId: root.id)
        guard let candidate=scan.candidates.first(where: { $0.relativePath == "project/target" && $0.eligible }) else { throw ShouError("io_error", "Expected fixture candidate is missing.") }
        return (engine, root, scan, candidate)
    }
}

/// Tests never send data to the user's system Trash.
struct FixtureFileSystem: PlatformFileSystem {
    let native: NativeFileSystem
    let trash: URL
    var platform: String { "macos" }
    var supportsTrash: Bool { true }
    func rootIdentity(_ path: String) throws -> FileEntry { try native.rootIdentity(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot { try native.inspect(path, budget: budget, cancelled: cancelled) }
    func availableBytes(_ path: String) -> Int64? { native.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { URL(fileURLWithPath: path).deletingLastPathComponent().path == trash.path }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult {
        let before=try native.inspect(path, budget: ScanBudget(), cancelled: { false })
        guard before.complete, before.entries == expected else { throw ShouError("plan_stale", "Fixture changed.") }
        let destination=trash.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: path), to: destination)
        let after=try native.inspect(destination.path, budget: ScanBudget(), cancelled: { false })
        return TrashResult(path: destination.path, manifest: after.entries, verified: after.complete)
    }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { try native.restore(path, to: destination, expected: expected) }
    func purge(_ path: String, expected: [FileEntry]) throws { try native.purge(path, expected: expected) }
}

func importIsDisabledAndPreviewCannotExecute() async throws {
    let fixture=try Fixture()
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    _ = try await engine.importRule(fixtureRule())
    try expect(try await engine.configuration().bindings.isEmpty)
    let normal=try await engine.scan(workspaceId: root.id)
    try expect(normal.candidates.allSatisfy { !$0.ruleIds.contains("test.artifacts") })
    let preview=try await engine.scan(workspaceId: root.id, previewRule: CleanupRule.parse(fixtureRule()))
    try expect(preview.previewOnly)
    let id=try require(preview.candidates.first(where: \.eligible)?.id)
    try await expectThrows { try await engine.createPlan(scanId: preview.id, candidateIds: [id]) }
}

func completeTrashRestoreLoopAndRepeatRefusal() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    try expect(plan.items.count == 1)
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try expect(receipt.state == "completed")
    try expect(receipt.items[0].state == "trashed")
    try expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target").path))
    try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    let items=receipt.items.map(\.id)
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: items, action: "restore")
    let restored=try await engine.followUp(executionId: receipt.id, itemIds: items, action: "restore", confirmedDigest: digest)
    try expect(restored[0].state == "completed")
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
}

func fullManifestDetectsDescendantChange() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    try fixture.put("project/target/artifact.bin", "changed")
    try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    try expect(try await engine.history().isEmpty)
}

func exclusionChangesInvalidatePlan() async throws {
    let fixture=try Fixture()
    let (engine, root, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    _ = try await engine.setExclusion(workspaceId: root.id, pattern: "project/**", remove: false)
    try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    let fresh=try await engine.scan(workspaceId: root.id)
    try expect(fresh.candidates.first { $0.relativePath == candidate.relativePath }?.eligible == false)
}

func protectedDescendantBlocksParent() async throws {
    let fixture=try Fixture()
    try fixture.put("project/target/.git/config")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    _ = try await engine.importRule(fixtureRule())
    _ = try await engine.setRule(ruleId: "test.artifacts", workspaceId: root.id, enabled: true)
    let scan=try await engine.scan(workspaceId: root.id)
    let candidate=try require(scan.candidates.first { $0.relativePath == "project/target" })
    try expect(!candidate.eligible)
    try expect(candidate.reasons.contains("protected_content"))
}

func internalLinkDoesNotTraverseOrPurgeOutside() async throws {
    let fixture=try Fixture()
    let outside=fixture.base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let secret=outside.appendingPathComponent("keep.txt")
    try Data("preserve".utf8).write(to: secret)
    try FileManager.default.createSymbolicLink(at: fixture.workspace.appendingPathComponent("project/target/external"), withDestinationURL: outside)
    let (engine, _, scan, candidate)=try await fixture.ready()
    try expect(!scan.entries.contains { $0.path.contains("external/keep.txt") })
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    let items=receipt.items.map(\.id)
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: items, action: "purge")
    let purged=try await engine.followUp(executionId: receipt.id, itemIds: items, action: "purge", confirmedDigest: digest)
    try expect(purged[0].state == "completed")
    try expect(try String(contentsOf: secret, encoding: .utf8) == "preserve")
}

func ancestorLinksRefused() throws {
    let fixture=try Fixture()
    let link=fixture.base.appendingPathComponent("linked-workspace")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.workspace)
    try expectThrows { try fixture.fs.rootIdentity(link.path) }
    #if os(macOS)
    // An ancestor needs search access, not permission to list its siblings.
    let ancestor=fixture.workspace.appendingPathComponent("search-only")
    let target=ancestor.appendingPathComponent("readable-target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("verified".utf8).write(to: target.appendingPathComponent("artifact.bin"))
    let permissions=try require(FileManager.default.attributesOfItem(atPath: ancestor.path)[.posixPermissions])
    try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: ancestor.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: ancestor.path) }
    if getuid() != 0 {
        do { _ = try FileManager.default.contentsOfDirectory(atPath: ancestor.path); throw CheckFailure(description: "The fixture ancestor must not be listable.") }
        catch is CheckFailure { throw CheckFailure(description: "The fixture ancestor unexpectedly allowed enumeration.") }
        catch { }
    }
    let scanned=try fixture.fs.inspect(target.path, budget: ScanBudget(), cancelled: { false })
    try expect(scanned.complete && scanned.entries.contains { $0.path == "artifact.bin" })
    #endif
}

func budgetInterruptionExplicitlyPartial() throws {
    let fixture=try Fixture()
    let snapshot=try fixture.fs.inspect(fixture.workspace.path, budget: ScanBudget(maxEntries: 2), cancelled: { false })
    try expect(!snapshot.complete)
    try expect(snapshot.issues.contains("resource_limit"))
    try fixture.put("aaa-complete/item.bin")
    let bounded=try fixture.fs.inspect(fixture.workspace.path, budget: ScanBudget(maxEntries: 4), cancelled: { false })
    try expect(!bounded.complete)
    try expect(bounded.completedPaths == ["aaa-complete"])
}

func crossProcessLockCannotBeAcquiredTwice() throws {
    let fixture=try Fixture()
    let lease=try fixture.store.lock(); defer { lease.release() }
    let other=try LocalRecordStore(directory: fixture.store.directory)
    try expectThrows { try other.lock() }
}

func restoreNeverOverwritesAndTrashExpansionBlocksPurge() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try fixture.put("project/target/new.bin", "must survive")
    let items=receipt.items.map(\.id)
    let restoreDigest=try await engine.followUpDigest(executionId: receipt.id, itemIds: items, action: "restore")
    let restored=try await engine.followUp(executionId: receipt.id, itemIds: items, action: "restore", confirmedDigest: restoreDigest)
    try expect(restored[0].state == "failed")
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/target/new.bin"), encoding: .utf8) == "must survive")
    let trash=URL(fileURLWithPath: try require(receipt.items[0].trashPath))
    try Data("new".utf8).write(to: trash.appendingPathComponent("unexpected.bin"))
    let purgeDigest=try await engine.followUpDigest(executionId: receipt.id, itemIds: items, action: "purge")
    try await expectThrows { try await engine.followUp(executionId: receipt.id, itemIds: items, action: "purge", confirmedDigest: purgeDigest) }
    try expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("artifact.bin").path))
}

func identicalImportIsIdempotentAndMutationConflicts() async throws {
    let fixture=try Fixture()
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let first=try await engine.importRule(fixtureRule())
    let second=try await engine.importRule(fixtureRule())
    try expect(first.digest == second.digest)
    try expect(try await engine.configuration().rules.count == 1)
    try await expectThrows { try await engine.importRule(fixtureRule(minimum: 1)) }
}

struct UnwritableJournalStore: RecordStore {
    let wrapped: LocalRecordStore
    var protectedPaths: [String] { wrapped.protectedPaths }
    func read(_ collection: String, id: String) throws -> Data? { try wrapped.read(collection, id: id) }
    func ids(_ collection: String) throws -> [String] { try wrapped.ids(collection) }
    func lock() throws -> any StoreLease { try wrapped.lock() }
    func write(_ collection: String, id: String, data: Data) throws {
        if collection == "history" { throw ShouError("journal_unavailable", "Injected durable journal failure.") }
        try wrapped.write(collection, id: id, data: data)
    }
}

func journalFailurePreventsMutation() async throws {
    let fixture=try Fixture()
    let (original, _, scan, candidate)=try await fixture.ready()
    let plan=try await original.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let engine=ShouEngine(store: UnwritableJournalStore(wrapped: fixture.store), filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), artifactEvidence: ArtifactFixtureEvidence())
    try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
    try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

func replacementDirectoryIsNotProcessed() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    try FileManager.default.moveItem(at: fixture.workspace.appendingPathComponent("project/target"), to: fixture.base.appendingPathComponent("original-target"))
    try fixture.put("project/target/new.bin", "replacement must survive")
    try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/target/new.bin"), encoding: .utf8) == "replacement must survive")
}

func persistedPlanCannotBypassCurrentPolicy() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    var plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    plan.items[0].candidate.relativePath="project"
    plan.digest=try plan.calculatedDigest()
    try fixture.store.write("plans", id: plan.id, data: Codec.encode(plan))
    try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/Cargo.toml").path))
}

func wrongConfirmationAndPartialScansCannotExecute() async throws {
    let fixture=try Fixture()
    let (engine, workspace, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: "wrong", entryPoint: "test") }
    let partial=try await engine.scan(workspaceId: workspace.id, budget: ScanBudget(maxEntries: 2))
    try expect(partial.status == "partial")
    try await expectThrows { try await engine.createPlan(scanId: partial.id, candidateIds: ["fake"]) }
    try expect(try await engine.history().isEmpty)
}

func protectedStoreCannotBecomeCleanupTarget() async throws {
    let fixture=try Fixture()
    let nestedStore=try LocalRecordStore(directory: fixture.workspace.appendingPathComponent("project/target/shou-records"))
    let engine=ShouEngine(store: nestedStore, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    _ = try await engine.importRule(fixtureRule())
    _ = try await engine.setRule(ruleId: "test.artifacts", workspaceId: root.id, enabled: true)
    let snapshot=try await engine.scan(workspaceId: root.id)
    let target=try require(snapshot.candidates.first { $0.relativePath == "project/target" })
    try expect(!target.eligible && target.reasons.contains("protected_content"))
}

func workspaceRemovalPreservesFilesAndHistory() async throws {
    let fixture=try Fixture()
    let (engine, workspace, _, _)=try await fixture.ready()
    _ = try await engine.savePreset(name: "Fixture", workspaceId: workspace.id, ruleIds: ["test.artifacts"])
    try await engine.removeWorkspace(workspace.id)
    let config=try await engine.configuration()
    try expect(config.workspaces.isEmpty && config.bindings.isEmpty && config.presets.isEmpty)
    try expect(config.rules.count == 1)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
}

func nativeArtifactFactsVerifyRetainedCargoSources() throws {
    #if os(macOS)
    let fixture=try Fixture(), evidence=NativeArtifactEvidence()
    let registry=fixture.base.appendingPathComponent("cargo/registry")
    let source=registry.appendingPathComponent("src/index-12345678/demo-1.0.0")
    let cache=registry.appendingPathComponent("cache/index-12345678")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("src"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let files=["Cargo.toml": "[package]\nname = 'demo'\nversion = '1.0.0'\n", "src/lib.rs": "pub fn value() -> u8 { 1 }\n"]
    for (name, contents) in files { try Data(contents.utf8).write(to: source.appendingPathComponent(name)) }
    let archive=cache.appendingPathComponent("demo-1.0.0.crate")
    func createArchive(_ archive: URL, from directory: URL, members: [String]) throws {
        let tar=Process()
        tar.executableURL=URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments=["-czf", archive.path, "-C", directory.path, "--"] + members
        tar.environment=["PATH": "/usr/bin:/bin", "LC_ALL": "C", "COPYFILE_DISABLE": "1"]
        tar.standardInput=FileHandle.nullDevice; tar.standardOutput=FileHandle.nullDevice; tar.standardError=FileHandle.nullDevice
        try tar.run(); tar.waitUntilExit()
        try expect(tar.terminationStatus == 0)
    }
    try createArchive(archive, from: source.deletingLastPathComponent(), members: [source.lastPathComponent])
    let package=String(Digest.sha256(try Data(contentsOf: archive)).dropFirst(7))
    var hashes=files.mapValues { String(Digest.sha256(Data($0.utf8)).dropFirst(7)) }
    func checksum(_ package: String) throws {
        let data=try JSONSerialization.data(withJSONObject: ["files": hashes, "package": package], options: [.sortedKeys])
        try data.write(to: source.appendingPathComponent(".cargo-checksum.json"))
    }
    func manifest() throws -> [FileEntry] {
        let tree=try fixture.fs.inspect(source.path, budget: ScanBudget(), cancelled: { false })
        try expect(tree.complete)
        return tree.entries
    }
    try Data("{\"v\":1}".utf8).write(to: source.appendingPathComponent(".cargo-ok"))
    try checksum(package)
    try expect(!(try evidence.hasGitTrackedFiles(at: source.path)))
    let ownName=URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    try expect(try evidence.runningBuildProcesses(in: [ownName]).contains(ownName))
    try expect(try evidence.cargoSourceIntegrity(at: source.path, expected: manifest()) == .verified)
    try checksum(String(repeating: "0", count: 64))
    do {
        _ = try evidence.cargoSourceIntegrity(at: source.path, expected: manifest())
        throw CheckFailure(description: "A mismatched retained archive must block source cleanup.")
    } catch let failure as ShouError { try expect(failure.code == "artifact_restore_unavailable") }

    // Rewriting the editable checksum must not bless locally modified source.
    let modified="pub fn value() -> u8 { 2 }\n"
    try Data(modified.utf8).write(to: source.appendingPathComponent("src/lib.rs"))
    hashes["src/lib.rs"]=String(Digest.sha256(Data(modified.utf8)).dropFirst(7))
    try checksum(package)
    try expect(try evidence.cargoSourceIntegrity(at: source.path, expected: manifest()) == .modified)
    try Data("private source".utf8).write(to: source.appendingPathComponent("private.rs"))
    try expect(try evidence.cargoSourceIntegrity(at: source.path, expected: manifest()) == .modified)
    try expect(try String(contentsOf: source.appendingPathComponent("src/lib.rs"), encoding: .utf8) == modified)

    func archiveCase(_ crate: String, local: [String: String], archived: [String: String], special: String? = nil) throws -> CargoSourceIntegrity {
        let source=registry.appendingPathComponent("src/index-12345678/" + crate)
        let staging=fixture.base.appendingPathComponent("archive-staging/" + crate)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, content) in local {
            let destination=source.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: destination)
        }
        for (name, content) in archived.sorted(by: { $0.key < $1.key }) {
            let destination=staging.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if name == "b.txt", let special {
                switch special {
                case "symlink": try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "a.txt")
                case "hardlink": try FileManager.default.linkItem(at: staging.appendingPathComponent("a.txt"), to: destination)
                case "fifo": try expect(mkfifo(destination.path, mode_t(0o600)) == 0)
                case "directory": try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                default: throw CheckFailure(description: "Unsupported archive fixture type.")
                }
            } else {
                try Data(content.utf8).write(to: destination)
            }
        }
        let archive=cache.appendingPathComponent(crate + ".crate")
        try createArchive(archive, from: staging.deletingLastPathComponent(), members: archived.keys.sorted().map { crate + "/" + $0 })
        let checksums=local.mapValues { String(Digest.sha256(Data($0.utf8)).dropFirst(7)) }
        let package=String(Digest.sha256(try Data(contentsOf: archive)).dropFirst(7))
        try JSONSerialization.data(withJSONObject: ["files": checksums, "package": package], options: [.sortedKeys])
            .write(to: source.appendingPathComponent(".cargo-checksum.json"))
        let tree=try fixture.fs.inspect(source.path, budget: ScanBudget(), cancelled: { false })
        try expect(tree.complete)
        return try evidence.cargoSourceIntegrity(at: source.path, expected: tree.entries)
    }

    // Equal concatenated bytes must not hide different per-member boundaries.
    try expect(try archiveCase("boundaries-1.0.0", local: ["a.txt": "ab", "b.txt": "c"], archived: ["a.txt": "a", "b.txt": "bc"]) == .modified)
    let spaced=[" leading file.txt ": "first", "sub dir/ trailing file.txt ": "second"]
    try expect(try archiveCase("spaces-1.0.0", local: spaced, archived: spaced) == .verified)
    let unicode=["你好.txt": "source"]
    do {
        _ = try archiveCase("unicode-1.0.0", local: unicode, archived: unicode)
        throw CheckFailure(description: "Unsupported archive path encoding must fail closed.")
    } catch let failure as ShouError { try expect(failure.code == "artifact_evidence_unavailable") }
    let linked=["a.txt": "same", "b.txt": "same"]
    for type in ["symlink", "hardlink", "fifo", "directory"] {
        do {
            _ = try archiveCase(type + "-1.0.0", local: linked, archived: linked, special: type)
            throw CheckFailure(description: "Archive links, special files and directory type mismatches must fail closed.")
        } catch let failure as ShouError { try expect(failure.code == "artifact_evidence_unavailable") }
    }
    #endif
}
