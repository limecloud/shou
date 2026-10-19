import Foundation
import ShouCore
import ShouPlatform
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct FixtureApplicationActivity: ApplicationActivityChecking {
    func runningBundleIdentifiers(in identifiers: Set<String>) throws -> Set<String> { [] }
}

private struct FixtureArtifactEvidence: ArtifactEvidenceChecking {
    private let native=NativeArtifactEvidence()
    func hasGitTrackedFiles(at path: String) throws -> Bool { try native.hasGitTrackedFiles(at: path) }
    func cargoSourceIntegrity(at path: String, expected: [FileEntry]) throws -> CargoSourceIntegrity {
        try native.cargoSourceIntegrity(at: path, expected: expected)
    }
    // These generated workspaces have no active builds. Unrelated developer
    // processes on the test host must not make fixture coverage nondeterministic.
    func runningBuildProcesses(in names: Set<String>) throws -> Set<String> { [] }
}

private func writeFixture(_ path: URL, _ contents: String = "generated cleanup fixture") throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: path)
}

private func fileHashes(_ directory: URL) throws -> [String: String] {
    let iterator=FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
    var result: [String: String]=[:]
    for case let file as URL in iterator {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(directory.path.count + 1))]=Digest.sha256(try Data(contentsOf: file))
        }
    }
    return result
}

private func receiptObjectIsAbsentFromTrash(_ item: ItemReceipt) throws {
    let path=try require(item.trashPath)
    let original=try require(item.manifest.first { $0.path == "." })
    var current=stat()
    if lstat(path, &current) != 0 {
        try expect(errno == ENOENT)
        return
    }
    // Trash basenames may be reused by later operations, including another
    // process. Check only the returned path's identity, never its new contents.
    guard UInt64(current.st_dev) != original.device || UInt64(current.st_ino) != original.inode else {
        throw CheckFailure(description: "The receipt object still occupies its Trash path after the completed follow-up: \(path)")
    }
    print("Verified prior receipt object absent; its Trash path has been reused: \(path)")
}

private func prepareCargoSource(home: URL, source: URL, staging: URL) throws {
    let crate=source.lastPathComponent
    let original=staging.appendingPathComponent(crate)
    let files=["Cargo.toml": "[package]\nname = 'fixture'\nversion = '1.0.0'\n", "src/lib.rs": "pub fn fixture() {}\n"]
    for (relative, content) in files {
        try writeFixture(original.appendingPathComponent(relative), content)
        try writeFixture(source.appendingPathComponent(relative), content)
    }
    let archive=home.appendingPathComponent(".cargo/registry/cache/" + source.deletingLastPathComponent().lastPathComponent + "/" + crate + ".crate")
    try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
    let process=Process()
    process.executableURL=URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments=["-czf", archive.path, "-C", staging.path, crate]
    try process.run(); process.waitUntilExit()
    try expect(process.terminationStatus == 0)
    let hashes=files.mapValues { String(Digest.sha256(Data($0.utf8)).dropFirst("sha256:".count)) }
    let checksum: [String: Any]=["files": hashes, "package": String(Digest.sha256(try Data(contentsOf: archive)).dropFirst("sha256:".count))]
    try JSONSerialization.data(withJSONObject: checksum, options: [.sortedKeys]).write(to: source.appendingPathComponent(".cargo-checksum.json"))
}

/// Only generated fixtures enter the native system Trash. The entire Trash is never listed or emptied.
func nativeCatalogCleanupAndRestore(includePurge: Bool = false) async throws {
    let templates=try BuiltinCatalog.templates()
    var patternCount=0
    for template in templates {
        let fixture=try Fixture()
        let home=fixture.workspace
        let engine=ShouEngine(store: fixture.store, filesystem: NativeFileSystem(), applicationActivity: FixtureApplicationActivity(), artifactEvidence: FixtureArtifactEvidence(), homeDirectory: home)
        let workspace: Workspace
        if template.location == "projects" {
            let projects=home.appendingPathComponent("projects")
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            workspace=try await engine.addWorkspace(path: projects.path, rootRef: "native-projects")
        } else {
            let location=try require(KnownLocations.catalog(homeDirectory: home, platform: "macos").first { $0.id == template.location })
            try FileManager.default.createDirectory(atPath: location.path, withIntermediateDirectories: true)
            workspace=try await engine.workspaceForKnownLocation(template.location)
        }
        let root=URL(fileURLWithPath: workspace.path)
        var targets=Set<String>()
        for pattern in template.patterns {
            let relative=template.id == "shou.builtin.cargo-extracted-sources" ? "registry/src/registry-0123456789abcdef/fixture-1.0.0" : pattern.replacingOccurrences(of: "**/", with: "project/").replacingOccurrences(of: "*", with: "fixture")
            targets.insert(relative)
            let target=root.appendingPathComponent(relative)
            if template.id == "shou.builtin.cargo-extracted-sources" {
                try prepareCargoSource(home: home, source: target, staging: fixture.base.appendingPathComponent("archive-input"))
            } else {
                try writeFixture(target.appendingPathComponent("payload.bin"))
            }
            if let marker=template.marker { try writeFixture(target.deletingLastPathComponent().appendingPathComponent(marker), "{}") }
            if template.id == "shou.builtin.swift-build" {
                let project=String(relative.prefix(upTo: relative.range(of: "/.build/")!.lowerBound))
                try writeFixture(root.appendingPathComponent(project + "/Package.swift"), "// swift-tools-version: 6.0")
                try writeFixture(root.appendingPathComponent(project + "/.build/workspace-state.json"), "{}")
                try writeFixture(target.appendingPathComponent("description.json"), "{}")
                try writeFixture(target.appendingPathComponent("Fixture.build/DerivedSources/resource_bundle_accessor.swift"), "// Generated fixture")
            }
            if template.id == "shou.builtin.rust-target" {
                try writeFixture(target.appendingPathComponent("CACHEDIR.TAG"))
                try writeFixture(target.appendingPathComponent(".rustc_info.json"), "{}")
                try FileManager.default.createDirectory(at: target.appendingPathComponent("debug/.fingerprint"), withIntermediateDirectories: true)
                try writeFixture(target.appendingPathComponent("debug/build/fixture-0123456789abcdef/out/generated.rs"), "// Generated fixture")
            }
        }
        try writeFixture(root.appendingPathComponent("retained-personal-data/keep.txt"), "Keep this personal file.")
        let original=try fileHashes(home)

        func trash() async throws -> ExecutionReceipt {
            let scan=try await engine.scan(workspaceId: workspace.id, ruleIds: [template.id])
            try expect(scan.status == "complete")
            let selected=scan.candidates.filter { $0.eligible && $0.ruleIds.contains(template.id) }
            for target in targets {
                guard selected.contains(where: { $0.relativePath == target || target.hasPrefix($0.relativePath + "/") }) else {
                    let reasons=scan.candidates.first { $0.relativePath == target }?.reasons ?? ["missing candidate"]
                    throw CheckFailure(description: "\(template.id): \(target): \(reasons)")
                }
            }
            let plan=try await engine.createPlan(scanId: scan.id, candidateIds: selected.map(\.id))
            let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "native-release-test")
            try expect(receipt.state == "completed" && receipt.items.allSatisfy { $0.state == "trashed" })
            for item in receipt.items {
                try expect(!FileManager.default.fileExists(atPath: item.originalPath))
                try expect(NativeFileSystem().isTrashLocation(try require(item.trashPath)))
                try expect(FileManager.default.fileExists(atPath: try require(item.trashPath)))
            }
            return receipt
        }

        let moved=try await trash()
        let trashedInspection=try await engine.inspectHistory(executionId: moved.id)
        try expect(trashedInspection.status == "complete" && trashedInspection.items.allSatisfy { $0.state == "verified_trash" && $0.original.state == "missing" && $0.trash.state == "matches" })
        let itemIds=moved.items.map(\.id)
        let restoreDigest=try await engine.followUpDigest(executionId: moved.id, itemIds: itemIds, action: "restore")
        let restored=try await engine.followUp(executionId: moved.id, itemIds: itemIds, action: "restore", confirmedDigest: restoreDigest)
        try expect(restored.count == itemIds.count && restored.allSatisfy { $0.state == "completed" })
        for item in moved.items { try receiptObjectIsAbsentFromTrash(item) }
        try expect(try fileHashes(home) == original)
        let restoredInspection=try await engine.inspectHistory(executionId: moved.id)
        try expect(restoredInspection.status == "complete" && restoredInspection.items.allSatisfy { $0.state == "restored" && $0.original.state == "matches" && $0.trash.state == "missing" })

        if includePurge {
            let removed=try await trash()
            let purgeIds=removed.items.map(\.id)
            let purgeDigest=try await engine.followUpDigest(executionId: removed.id, itemIds: purgeIds, action: "purge")
            let purged=try await engine.followUp(executionId: removed.id, itemIds: purgeIds, action: "purge", confirmedDigest: purgeDigest)
            try expect(purged.count == purgeIds.count && purged.allSatisfy { $0.state == "completed" })
            for item in removed.items {
                try receiptObjectIsAbsentFromTrash(item)
                try expect(!FileManager.default.fileExists(atPath: item.originalPath))
            }
            let retained=original.filter { relative, _ in
                let absolute=home.appendingPathComponent(relative).path
                return !removed.items.contains { absolute == $0.originalPath || absolute.hasPrefix($0.originalPath + "/") }
            }
            try expect(try fileHashes(home) == retained)
        }
        patternCount += template.patterns.count
        let flow=includePurge ? "Trash → restore → Trash → purge" : "Trash → restore"
        print("PASS native \(flow): \(template.id) (\(template.patterns.count) patterns)")
    }
    print("Native cleanup verified: \(templates.count) rules, \(patternCount) patterns; restored file hashes and retained files match; purge \(includePurge ? "explicitly enabled" : "disabled").")
}
