import Foundation
import ShouCore
import ShouPlatform

func scanAccessPolicyProtectsExactBoundaries() throws {
    let policy=ScanPrivacyPolicy(status: .limited, home: "/Users/fixture")
    try expect(policy.requiresAuthorization("/Users/fixture/Library/Containers/com.example.app/Data"))
    try expect(policy.requiresAuthorization("/System/Volumes/Data/Users/fixture/Library/Containers"))
    try expect(policy.requiresAuthorization("/users/FIXTURE/library/containers/com.example.app"))
    try expect(policy.requiresAuthorization("/Users/fixture//Library///Containers/com.example.app"))
    try expect(policy.requiresAuthorization("/Users/fixture/Library/./Containers/com.example.app"))
    try expect(policy.requiresAuthorization("/Users/fixture/Documents/../Library/Containers"))
    try expect(policy.requiresAuthorization("/System//Volumes/Data/Users/fixture/Library/Containers"))
    try expect(ScanPrivacyPolicy(status: .limited, home: "/Users/fixture/").requiresAuthorization("/Users/fixture/Library/Containers"))
    try expect(ScanPrivacyPolicy(status: .limited, home: "/System/Volumes/Data/Users/fixture").requiresAuthorization("/Users/fixture/Library/Containers"))
    try expect(!policy.requiresAuthorization("/Users/fixture/Library/Containers-copy"))
    try expect(!policy.requiresAuthorization("/Users/fixture-other/Library/Containers"))
    try expect(!policy.requiresAuthorization("/Users/fixture/Documents/developer-project"))
    try expect(!policy.requiresAuthorization("/Users/fixture/Library/Caches/npm"))
    for status: DiskAccessStatus in [.available, .notRequired] {
        try expect(!ScanPrivacyPolicy(status: status, home: "/Users/fixture").requiresAuthorization("/Users/fixture/Library/Containers"))
    }
    try expect(ScanPrivacyPolicy(status: .unknown, home: "/Users/fixture").requiresAuthorization("/Users/fixture/.Trash"))
}

func scanAccessSkipsContainersAndPreservesAccessibleCoverage() async throws {
    let fixture=try Fixture()
    try fixture.put("Library/Containers/com.example.test/Data/secret.bin", "generated protected data")
    try fixture.put("Library/Caches/test/cache.bin", String(repeating: "c", count: 4096))
    try fixture.put("Documents/project/output.bin", String(repeating: "p", count: 8192))
    let privacy=ScanPrivacyPolicy(status: .limited, home: fixture.workspace.path)
    let filesystem=NativeFileSystem(scanPrivacyPolicy: privacy)
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem)
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    try expect(!scan.tree.complete)
    try expect(scan.tree.issues.contains("authorization_required: Library/Containers"))
    let library=try await engine.storageDirectory(scanId: scan.id, path: "Library")
    let protected=try require(library.children.first { $0.node.path == "Library/Containers" })
    try expect(protected.node.isComplete == false && protected.node.fileCount == 0)
    let empty=try await engine.storageDirectory(scanId: scan.id, path: "Library/Containers")
    try expect(empty.children.isEmpty)
    let documents=try await engine.storageDirectory(scanId: scan.id, path: "Documents")
    try expect(documents.item.node.isComplete == true && documents.item.node.fileCount == 1)
    let bounded=try filesystem.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { false }, progress: { _ in })
    try expect(!bounded.complete && bounded.issues.contains("authorization_required: Library/Containers"))
    try expect(!bounded.entries.contains { $0.path.contains("secret.bin") })
    try expect(bounded.entries.contains { $0.path == "Documents/project/output.bin" })
    try expectThrows { try filesystem.inspect(fixture.workspace.appendingPathComponent("Library/Containers").path, budget: ScanBudget(), cancelled: { false }) }
    let authorized=ShouEngine(store: fixture.store, filesystem: NativeFileSystem(scanPrivacyPolicy: .init(status: .available, home: fixture.workspace.path)))
    let complete=try await authorized.scanStorage(path: fixture.workspace.path)
    try expect(complete.tree.complete)
    let containers=try await authorized.storageDirectory(scanId: complete.id, path: "Library/Containers")
    try expect(containers.item.node.isComplete == true && containers.item.node.fileCount == 1)
}

func cliInstallationIsRepeatableAndPreservesConflicts() throws {
    let fixture=try Fixture()
    let home=fixture.workspace, app=home.appendingPathComponent("Shou's test.app")
    let binary=app.appendingPathComponent("Contents/Helpers/shou")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let launcher=try NativeCLIInstallation.install(app: app, home: home)
    try expect(try NativeCLIInstallation.install(app: app, home: home) == launcher)
    let process=Process(), output=Pipe()
    process.executableURL=launcher; process.arguments=["space containing argument", "--json"]
    process.standardOutput=output
    try process.run(); process.waitUntilExit()
    try expect(process.terminationStatus == 0)
    try expect(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "space containing argument\n--json\n")
    let conflict=Data("existing user command".utf8)
    try conflict.write(to: launcher)
    try expectThrows { try NativeCLIInstallation.install(app: app, home: home) }
    try expect(try Data(contentsOf: launcher) == conflict)
}

func cliInstallationPreservesSymbolicLinks() throws {
    let fixture=try Fixture(), home=fixture.workspace
    let app=home.appendingPathComponent("Shou.app"), binary=app.appendingPathComponent("Contents/Helpers/shou")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let original=home.appendingPathComponent("keep-original")
    try Data("keep".utf8).write(to: original)
    let entry=NativeCLIInstallation.launcher(home: home)
    try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: original)
    try expectThrows { try NativeCLIInstallation.install(app: app, home: home) }
    try expect(try Data(contentsOf: original) == Data("keep".utf8))
}
