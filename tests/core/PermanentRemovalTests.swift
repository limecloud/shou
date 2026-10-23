import Foundation
import ShouCore
import ShouPlatform
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func permanentRemovalContinuesPastPermissionFailuresAndLaterTargets() async throws {
    guard getuid() != 0 else { return }
    let fixture=try Fixture()
    try fixture.put("generated/z-locked/file.bin", "cannot unlink from a read-only directory")
    try fixture.put("generated/a-writable/file.bin", "remove this sibling")
    try fixture.put("later-cache/file.bin", "continue the selected batch")
    let locked=fixture.workspace.appendingPathComponent("generated/z-locked")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["generated", "later-cache"], action: "permanent")
    let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "permission-fixture")
    try expect(receipt.state == "partial" && receipt.items.count == 2)
    try expect(receipt.items[0].state == "failed" && receipt.items[1].state == "purged")
    try expect(receipt.items[0].error?.contains("z-locked/file.bin") == true)
    try expect(FileManager.default.fileExists(atPath: locked.appendingPathComponent("file.bin").path))
    try expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("generated/a-writable").path))
    try expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("later-cache").path))
    try await expectThrows { try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "permission-fixture") }
}

func nativePermanentRemovalRejectsReplacedCachedDirectories() throws {
    for replacement in ["nested", "root", "ancestor"] {
        let fixture=try Fixture()
        try fixture.put("generated/nested/z.bin", "first removal")
        try fixture.put("generated/nested/a.bin", "must survive replacement")
        let outside=fixture.base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside scope".utf8).write(to: outside.appendingPathComponent("a.bin"))
        let target=fixture.workspace.appendingPathComponent("generated")
        let replaced=replacement == "ancestor" ? fixture.workspace : replacement == "root" ? target : target.appendingPathComponent("nested")
        let detached=fixture.base.appendingPathComponent("detached")
        let manifest=try fixture.fs.inspectTarget(target.path, budget: ScanBudget(), cancelled: { false })
        var mutationError: Error?, replacedOnce=false
        try expectThrows {
            try fixture.fs.purge(target.path, expected: manifest.entries, progress: { completed, _, _ in
                guard completed == 1, !replacedOnce else { return }
                replacedOnce=true
                do {
                    try FileManager.default.moveItem(at: replaced, to: detached)
                    try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: outside)
                } catch { mutationError=error }
            })
        }
        if let mutationError { throw mutationError }
        try expect(replacedOnce)
        let retained=detached.appendingPathComponent(replacement == "ancestor" ? "generated/nested/a.bin" : replacement == "root" ? "nested/a.bin" : "a.bin")
        try expect(try String(contentsOf: retained, encoding: .utf8) == "must survive replacement")
        try expect(try String(contentsOf: outside.appendingPathComponent("a.bin"), encoding: .utf8) == "outside scope")
    }
}

func nativePermanentRemovalPreservesNewUnplannedFiles() throws {
    let fixture=try Fixture()
    let target=fixture.workspace.appendingPathComponent("project/target")
    let manifest=try fixture.fs.inspectTarget(target.path, budget: ScanBudget(), cancelled: { false })
    let added=target.appendingPathComponent("unplanned.bin")
    var mutationError: Error?
    try expectThrows {
        try fixture.fs.purge(target.path, expected: manifest.entries, progress: { completed, _, _ in
            guard completed == 1 else { return }
            do { try Data("keep new content".utf8).write(to: added) }
            catch { mutationError=error }
        })
    }
    if let mutationError { throw mutationError }
    try expect(try String(contentsOf: added, encoding: .utf8) == "keep new content")
}

func nativePermanentRemovalReportsProgressForDeepDirectories() throws {
    let fixture=try Fixture()
    let prefix="generated/" + Array(repeating: "nested", count: 12).joined(separator: "/")
    let directory=fixture.workspace.appendingPathComponent(prefix)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bytes=Data("generated".utf8)
    for index in 0..<10_000 {
        try bytes.write(to: directory.appendingPathComponent("file-\(index).bin"))
    }
    let target=fixture.workspace.appendingPathComponent("generated").path
    let manifest=try fixture.fs.inspectTarget(target, budget: ScanBudget(), cancelled: { false })
    try expect(manifest.complete)
    let started=Date()
    var previous=0, updates=0, validProgress=true
    try fixture.fs.purge(target, expected: manifest.entries, progress: { completed, total, _ in
        validProgress = validProgress && total == manifest.entries.count && completed > previous
        previous=completed; updates += 1
    })
    try expect(validProgress && previous == manifest.entries.count && updates >= 2)
    try expect(!FileManager.default.fileExists(atPath: target))
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
    print("permanent removal: entries=\(manifest.entries.count) depth=12 elapsed=\(String(format: "%.3f", Date().timeIntervalSince(started)))s")
}

func nativePermanentRemovalHandlesNestedAndRetainedHardLinks() throws {
    let fixture=try Fixture()
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    let retained=fixture.workspace.appendingPathComponent("retained.bin")
    try FileManager.default.linkItem(at: source, to: retained)
    try fixture.put("project/target/nested/other.bin", "independent file")
    try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent("project/target/nested/shared.bin"))
    try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent("project/target/shared.bin"))
    let bytes=try Data(contentsOf: retained)
    let path=source.deletingLastPathComponent().path
    let manifest=try fixture.fs.inspectTarget(path, budget: ScanBudget(), cancelled: { false })
    try expect(manifest.complete)
    try fixture.fs.purge(path, expected: manifest.entries)
    try expect(!FileManager.default.fileExists(atPath: path))
    try expect(try Data(contentsOf: retained) == bytes)
    let remaining=try fixture.fs.inspectTarget(retained.path, budget: ScanBudget(), cancelled: { false })
    try expect(remaining.entries.first?.links == 1)
}

func permanentRuleBatchHandlesHardLinksAcrossTargets() async throws {
    let fixture=try Fixture()
    try fixture.put("second/Cargo.toml", "[package]\nname = 'second'\n")
    try fixture.put("second/target/nested/independent.bin", "keep batch progressing")
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    for relative in ["second/target/a.bin", "second/target/nested/z.bin", "retained.bin"] {
        try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent(relative))
    }
    let (engine, _, scan, _)=try await fixture.ready()
    let candidates=scan.candidates.filter { ["project/target", "second/target"].contains($0.relativePath) && $0.eligible }
    try expect(candidates.count == 2)
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: candidates.map(\.id), action: "permanent")
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "hardlink-fixture")
    try expect(receipt.state == "completed" && receipt.items.allSatisfy { $0.state == "purged" })
    for item in receipt.items { try expect(!FileManager.default.fileExists(atPath: item.originalPath)) }
    try expect(try Data(contentsOf: fixture.workspace.appendingPathComponent("retained.bin")) == Data(repeating: 120, count: 8192))
    let fresh=try await engine.scan(workspaceId: scan.workspace.id)
    try expect(!fresh.candidates.contains { candidates.map(\.relativePath).contains($0.relativePath) })
}

func permanentStorageBatchHandlesSharedFilesAndDirectories() async throws {
    let fixture=try Fixture()
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    try fixture.put("second-cache/independent.bin", "second target")
    for relative in ["loose.bin", "second-cache/a.bin", "second-cache/z.bin", "retained.bin"] {
        try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent(relative))
    }
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let scan=try await engine.scanStorage(path: fixture.workspace.path, budget: ScanBudget())
    let selected=["project/target/artifact.bin", "second-cache", "loose.bin"]
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: selected, action: "permanent")
    let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "hardlink-fixture")
    try expect(receipt.state == "completed" && receipt.items.count == 3 && receipt.items.allSatisfy { $0.state == "purged" })
    for relative in selected { try expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent(relative).path)) }
    try expect(try Data(contentsOf: fixture.workspace.appendingPathComponent("retained.bin")) == Data(repeating: 120, count: 8192))
}

func permanentRemovalStillRejectsExternallyChangedHardLinks() throws {
    let fixture=try Fixture()
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    let retained=fixture.workspace.appendingPathComponent("retained.bin")
    try FileManager.default.linkItem(at: source, to: retained)
    let target=source.deletingLastPathComponent().path
    let manifest=try fixture.fs.inspectTarget(target, budget: ScanBudget(), cancelled: { false })
    try Data("externally changed content".utf8).write(to: retained)
    try expectThrows { try fixture.fs.purge(target, expected: manifest.entries) }
    try expect(FileManager.default.fileExists(atPath: source.path))
    try expect(try Data(contentsOf: retained) == Data("externally changed content".utf8))
}

func permanentRemovalContextRejectsUnrelatedMetadataChanges() throws {
    let fixture=try Fixture()
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent("retained.bin"))
    let before=try require(fixture.fs.inspectTarget(source.path, budget: ScanBudget(), cancelled: { false }).entries.first)
    var context=PermanentRemovalContext(), after=before
    after.links -= 1; after.changedNanoseconds += 1
    try context.recordUnlink(before: before, after: after)
    try expect(context.reconciled([before]) == [after])
    var modified=before; modified.logicalBytes += 1
    try expect(context.reconciled([modified]) == [modified])
    var invalid=after; invalid.mode ^= 1
    var rejected=PermanentRemovalContext()
    try expectThrows { try rejected.recordUnlink(before: before, after: invalid) }
    invalid=after; invalid.links=before.links
    try expectThrows { try rejected.recordUnlink(before: before, after: invalid) }
    try expect(PermanentRemovalContext().reconciled([before]) == [before])
}

private final class MutateAfterFirstPurge: @unchecked Sendable {
    private let lock=NSLock()
    private var changed=false
    private var failure: Error?
    let retained: URL
    init(retained: URL) { self.retained=retained }
    func observe(_ update: ExecutionProgress) {
        lock.lock(); defer { lock.unlock() }
        guard !changed, update.stage == "purging", update.processedCount == 1 else { return }
        changed=true
        do { try Data("changed after the first target was removed".utf8).write(to: retained) }
        catch { failure=error }
    }
    func verify() throws {
        lock.lock(); defer { lock.unlock() }
        try expect(changed)
        if let failure { throw failure }
    }
}

func permanentBatchRefusesExternalChangeAfterItsOwnUnlink() async throws {
    let fixture=try Fixture()
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    try fixture.put("second-cache/independent.bin", "remaining target")
    for relative in ["second-cache/shared.bin", "retained.bin"] {
        try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent(relative))
    }
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let scan=try await engine.scanStorage(path: fixture.workspace.path, budget: ScanBudget())
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["project/target/artifact.bin", "second-cache"], action: "permanent")
    let mutation=MutateAfterFirstPurge(retained: fixture.workspace.appendingPathComponent("retained.bin"))
    let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "external-change-fixture", progress: { mutation.observe($0) })
    try mutation.verify()
    try expect(receipt.state == "partial" && receipt.items[0].state == "purged" && receipt.items[1].state == "failed")
    try expect(!FileManager.default.fileExists(atPath: receipt.items[0].originalPath))
    try expect(FileManager.default.fileExists(atPath: receipt.items[1].originalPath))
    try expect(try Data(contentsOf: mutation.retained) == Data("changed after the first target was removed".utf8))
}

func trashFollowUpPurgesHardLinksAcrossRecordedTargets() async throws {
    let fixture=try Fixture()
    try fixture.put("second/Cargo.toml", "[package]\nname = 'second'\n")
    try fixture.put("second/target/independent.bin", "second target")
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    for relative in ["second/target/a.bin", "second/target/z.bin", "retained.bin"] {
        try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent(relative))
    }
    let (engine, _, scan, _)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: scan.candidates.filter(\.eligible).map(\.id))
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "hardlink-fixture")
    try expect(receipt.state == "completed" && receipt.items.count == 2)
    let ids=receipt.items.map(\.id)
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "purge")
    let results=try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "purge", confirmedDigest: digest)
    try expect(results.count == 2 && results.allSatisfy { $0.state == "completed" })
    for item in receipt.items { try expect(!FileManager.default.fileExists(atPath: try require(item.trashPath))) }
    try expect(try Data(contentsOf: fixture.workspace.appendingPathComponent("retained.bin")) == Data(repeating: 120, count: 8192))
}
