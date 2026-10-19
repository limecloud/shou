import Foundation
import ShouCore
import ShouPlatform
#if canImport(Darwin)
import Darwin
#endif

#if os(macOS)
private func largeTargetManifest(_ tree: TreeSnapshot, matches expected: [FileEntry]) throws {
    try expect(tree.complete && tree.entries.count == expected.count)
    let before=try require(expected.first { $0.path == "." })
    let after=try require(tree.entries.first { $0.path == "." })
    try expect(before.sameObject(as: after) && after.kind == "directory")
    // A rename can change root ctime; every descendant must remain identical.
    try expect(tree.entries.filter { $0.path != "." } == expected.filter { $0.path != "." })
}

private func largeTargetHashes(_ directory: URL, paths: [String]) throws -> [String: String] {
    try Dictionary(uniqueKeysWithValues: paths.map { path in
        (path, Digest.sha256(try Data(contentsOf: directory.appendingPathComponent(path))))
    })
}

private func makeLargeTargetFiles(_ target: URL) throws -> Int {
    let buckets=100, perBucket=1001
    for bucket in 0..<buckets {
        let directory=target.appendingPathComponent(String(format: "bucket-%03d", bucket), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor=open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CheckFailure(description: "Could not open a generated large-target bucket.") }
        do {
            defer { close(descriptor) }
            for index in 0..<perBucket {
                let name=String(format: "file-%04d.bin", index)
                let file=openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
                guard file >= 0 else { throw CheckFailure(description: "Could not create a distinct generated large-target file.") }
                close(file)
            }
        }
    }
    return buckets * perBucket
}
#endif

/// Explicit-only native regression. It never purges or enumerates the full Trash.
func nativeLargeTargetTrashAndRestore() async throws {
    #if os(macOS)
    let temporary=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let physical=temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
    let base=URL(fileURLWithPath: physical).appendingPathComponent("shou-native-large-" + UUID().uuidString, isDirectory: true)
    let workspace=base.appendingPathComponent("workspace", isDirectory: true)
    let project=workspace.appendingPathComponent("project", isDirectory: true)
    let target=project.appendingPathComponent("generated-cache", isDirectory: true)
    let storePath=base.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let filesystem=NativeFileSystem(), store=try LocalRecordStore(directory: storePath)
    let engine=ShouEngine(store: store, filesystem: filesystem, artifactEvidence: NativeArtifactEvidence())
    let budget=ScanBudget(maxEntries: 250_000, maxSeconds: 600)
    var expectedManifest: [FileEntry]=[]
    var executionId: String?
    print("Native large target fixture: \(base.path)")
    do {
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("[package]\nname = 'native-large-fixture'\nversion = '0.1.0'\n".utf8).write(to: project.appendingPathComponent("Cargo.toml"))
        try Data("fn main() { println!(\"Retain source\"); }\n".utf8).write(to: project.appendingPathComponent("src/main.rs"))
        try Data("Retain this user-authored fixture file.\n".utf8).write(to: project.appendingPathComponent("keep.txt"))
        let keptPaths=["Cargo.toml", "src/main.rs", "keep.txt"]
        let kept=try largeTargetHashes(project, paths: keptPaths)
        let emptyFileCount=try makeLargeTargetFiles(target)
        let sentinels=["sentinel.bin", "bucket-000/sentinel-first.bin", "bucket-099/sentinel-last.bin"]
        for (index, path) in sentinels.enumerated() {
            try Data("Large-target sentinel \(index): \(base.lastPathComponent)\n".utf8).write(to: target.appendingPathComponent(path))
        }
        let sentinelHashes=try largeTargetHashes(target, paths: sentinels)
        let fileCount=emptyFileCount + sentinels.count
        try expect(fileCount > 100_000)
        print("Native large target: created \(fileCount) distinct files; scanning the full workspace.")

        let binding=try await engine.addWorkspace(path: workspace.path, rootRef: "test-workspace")
        _ = try await engine.importRule(fixtureRule(pattern: "**/generated-cache"))
        _ = try await engine.setRule(ruleId: "test.artifacts", workspaceId: binding.id, enabled: true)
        let scan=try await engine.scan(workspaceId: binding.id, ruleIds: ["test.artifacts"], scope: .full, budget: budget)
        try expect(scan.status == "complete" && scan.treeComplete == true && scan.scope == .full)
        let candidate=try require(scan.candidates.first { $0.relativePath == "project/generated-cache" && $0.eligible })
        let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
        try expect(plan.items.count == 1)
        expectedManifest=try require(plan.items.first).manifest
        let files=expectedManifest.filter { $0.kind == "file" }
        try expect(files.count == fileCount && expectedManifest.count > 100_000)
        try expect(Set(files.map { "\($0.device):\($0.inode)" }).count == fileCount)
        print("Native large target: plan covers \(expectedManifest.count) entries; moving to the system Trash.")

        let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "native-large-target-regression")
        executionId=receipt.id
        let item=try require(receipt.items.first)
        try expect(receipt.items.count == 1 && receipt.state == "completed" && item.state == "trashed")
        let trashPath=try require(item.trashPath)
        try expect(!FileManager.default.fileExists(atPath: target.path) && filesystem.isTrashLocation(trashPath))
        try expect(item.manifest.count == expectedManifest.count)
        let trashed=try filesystem.inspect(trashPath, budget: budget, cancelled: { false })
        try largeTargetManifest(trashed, matches: expectedManifest)
        try expect(trashed.entries == item.manifest)
        try expect(try largeTargetHashes(URL(fileURLWithPath: trashPath), paths: sentinels) == sentinelHashes)
        try expect(try largeTargetHashes(project, paths: keptPaths) == kept)
        print("Native large target: verified all \(trashed.entries.count) Trash entries; restoring the exact receipt item.")

        let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: [item.id], action: "restore")
        let restored=try await engine.followUp(executionId: receipt.id, itemIds: [item.id], action: "restore", confirmedDigest: digest)
        try expect(restored.count == 1 && restored[0].state == "completed" && restored[0].resultingPath == target.path)
        try expect(!FileManager.default.fileExists(atPath: trashPath))
        let returned=try filesystem.inspect(target.path, budget: budget, cancelled: { false })
        try largeTargetManifest(returned, matches: expectedManifest)
        try expect(try largeTargetHashes(target, paths: sentinels) == sentinelHashes)
        try expect(try largeTargetHashes(project, paths: keptPaths) == kept)
        print("Native large target: restored \(fileCount) files, full descendant metadata, sentinel hashes, and retained source; no purge.")
        try FileManager.default.removeItem(at: base)
    } catch {
        let originalError=error
        var recoveryFailures: [String]=[]
        // Recover only exact destination paths recorded for this isolated target.
        // An unknown result can be restored only after reproducing its full
        // original manifest, including the root inode and every descendant.
        let records: [ExecutionReceipt]
        do { records=try await engine.history() }
        catch { records=[]; recoveryFailures.append("History unavailable: \(error)") }
        for receipt in records {
            for item in receipt.items where item.originalPath == target.path {
                guard let trashPath=item.trashPath else {
                    if !FileManager.default.fileExists(atPath: target.path) {
                        recoveryFailures.append("Receipt \(receipt.id) item \(item.id) has no destination for the missing generated target.")
                    }
                    continue
                }
                print("Native large target recorded destination: \(trashPath)")
                if FileManager.default.fileExists(atPath: target.path), !FileManager.default.fileExists(atPath: trashPath) { continue }
                do {
                    guard !FileManager.default.fileExists(atPath: target.path), filesystem.isTrashLocation(trashPath), !expectedManifest.isEmpty else {
                        throw CheckFailure(description: "Recovery scope or destination cannot be verified; preserve evidence.")
                    }
                    if item.state == "trashed" {
                        do {
                            let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: [item.id], action: "restore")
                            let results=try await engine.followUp(executionId: receipt.id, itemIds: [item.id], action: "restore", confirmedDigest: digest)
                            if results.count == 1 && results[0].state == "completed" { continue }
                        } catch { print("Native large target receipt recovery requires direct verified restoration: \(error)") }
                    }
                    if FileManager.default.fileExists(atPath: target.path), !FileManager.default.fileExists(atPath: trashPath) { continue }
                    let current=try filesystem.inspect(trashPath, budget: budget, cancelled: { false })
                    try largeTargetManifest(current, matches: expectedManifest)
                    try filesystem.restore(trashPath, to: target.path, expected: current.entries)
                    print("Native large target recovered its recorded destination without purging.")
                } catch { recoveryFailures.append("\(trashPath): \(error)") }
            }
        }
        if !expectedManifest.isEmpty, !FileManager.default.fileExists(atPath: target.path) {
            recoveryFailures.append("The generated target remains unavailable; preserve recorded paths for manual inspection.")
        }
        let details="Fixture: \(base.path); store: \(storePath.path); execution: \(executionId ?? "inspect isolated history")"
        print("Native large target preserved failure evidence. \(details)")
        if !recoveryFailures.isEmpty { print("Native large target recovery details: \(recoveryFailures.joined(separator: "; "))") }
        throw CheckFailure(description: "\(originalError). \(details). Recovery: \(recoveryFailures.isEmpty ? "completed or no known Trash items" : recoveryFailures.joined(separator: "; "))")
    }
    #else
    throw CheckFailure(description: "The native large-target Trash regression requires macOS.")
    #endif
}
