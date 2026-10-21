import Foundation
import ShouCore
import ShouPlatform

private final class ToolFixtureRunner: CleanupToolRunning, @unchecked Sendable {
    private let lock=NSLock()
    private var removed=Set<String>()
    private var mutations=[CleanupToolCommand]()
    var remote=false
    var changed=false
    var failMutation=false
    var mutationCount: Int { lock.lock(); defer { lock.unlock() }; return mutations.count }
    func run(_ command: CleanupToolCommand, timeoutSeconds: Double) throws -> CleanupToolOutput {
        lock.lock(); defer { lock.unlock() }
        if command.mutating {
            mutations.append(command)
            if failMutation { throw ShouError("tool_timeout", "Generated tool timeout.") }
            removed.insert(command.tool)
        }
        let text: String
        switch command {
        case .dockerContext: text=remote ? "\"tcp://remote:2376\"" : "\"unix:///var/run/docker.sock\""
        case .dockerPreview: text="{\"Type\":\"Build Cache\",\"Reclaimable\":\"" + (removed.contains("docker") ? "0B" : changed ? "4MB" : "2MB") + "\"}\n"
        case .brewPreview: text=removed.contains("brew") ? "" : "Would remove: /fixture/old (3MB)\n"
        case .condaPreview: text="{\"success\":true,\"tarballs\":{\"total_size\":" + (removed.contains("conda") ? "0" : "4096") + "}}"
        case .rustList: text="stable-aarch64-apple-darwin (active, default) /fixture/stable\nnightly-aarch64-apple-darwin /fixture/nightly\n" + (removed.contains("rustup") ? "" : "1.75.0-aarch64-apple-darwin /fixture/old\n")
        case .rustOverrides: text="/fixture/pinned\tnightly-aarch64-apple-darwin\n"
        case .rustDefault: text="stable-aarch64-apple-darwin (default)"
        default: text="done"
        }
        return .init(text: text, executableIdentity: "generated-" + command.tool)
    }
}

func toolCleanupUsesFixedOwnerOperationsAndVerifiesOutcomes() async throws {
    let fixture=try Fixture(), runner=ToolFixtureRunner()
    let service=ToolCleanupService(runner: runner, store: fixture.store)
    let scan=try await service.scan()
    try expect(scan.issues.isEmpty && scan.targets.count == 4)
    try expect(!scan.targets.contains { $0.toolchain?.hasPrefix("stable") == true || $0.toolchain?.hasPrefix("nightly") == true })
    for target in scan.targets {
        let plan=try await service.createPlan(scanId: scan.id, targetId: target.id)
        try await expectThrows { try await service.execute(planId: plan.id, confirmedDigest: "wrong") }
        let receipt=try await service.execute(planId: plan.id, confirmedDigest: plan.digest)
        try expect(receipt.state == "completed")
        try await expectThrows { try await service.execute(planId: plan.id, confirmedDigest: plan.digest) }
    }
    let history = try await service.history()
    try expect(runner.mutationCount == 4 && history.count == 4)
    try expect(try await service.scan().targets.isEmpty)
    try expect(CleanupToolCommand.dockerPrune.arguments == ["--context","default","builder","prune","--all","--force"])
    try expect(!CleanupToolCommand.dockerPrune.arguments.contains("volume"))
    try expect(CleanupToolCommand.brewPreview.arguments.filter { $0 != "--dry-run" } == CleanupToolCommand.brewPrune.arguments)
}

func toolCleanupRejectsRemoteStaleAndUnknownOutcomes() async throws {
    let fixture=try Fixture(), runner=ToolFixtureRunner()
    let service=ToolCleanupService(runner: runner, store: fixture.store)
    runner.remote=true
    let remote=try await service.scan()
    try expect(!remote.targets.contains { $0.tool == "docker" } && remote.issues.contains { $0.code == "remote_context" })
    runner.remote=false
    let scan=try await service.scan(), target=try require(scan.targets.first { $0.tool == "docker" })
    let plan=try await service.createPlan(scanId: scan.id, targetId: target.id)
    runner.changed=true
    try await expectThrows { try await service.execute(planId: plan.id, confirmedDigest: plan.digest) }
    try expect(runner.mutationCount == 0)
    runner.changed=false; runner.failMutation=true
    let outcome=try await service.execute(planId: plan.id, confirmedDigest: plan.digest)
    try expect(outcome.state == "unknown" && outcome.error != nil)
    try await expectThrows { try await service.execute(planId: plan.id, confirmedDigest: plan.digest) }
    try expect(runner.mutationCount == 1)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
    try expectThrows { try NativeCleanupTools().run(.rustRemove("--default"), timeoutSeconds: 1) }
}

func nativeToolAdapterBoundsRealFixtureProcesses() throws {
    let fixture=try Fixture()
    let relative=".cargo/bin/rustup", executable=fixture.workspace.appendingPathComponent(relative)
    try fixture.put(relative, "#!/bin/sh\nprintf 'fixture-工具\\n'\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let runner=NativeCleanupTools(homeDirectory: fixture.workspace)
    let result=try runner.run(.rustList, timeoutSeconds: 2)
    try expect(result.text == "fixture-工具\n")
    try expect(result.executableIdentity.hasPrefix(executable.resolvingSymlinksInPath().path + ":"))
    // The generated child's delayed write must never survive a timeout, even
    // after its launcher exits. No real tool or user configuration is used.
    try fixture.put(relative, "#!/bin/sh\n(/bin/sleep 2; /usr/bin/touch \"$HOME/escaped-child\") &\nexit 0\n")
    do {
        _ = try runner.run(.rustList, timeoutSeconds: 1)
        throw CheckFailure(description: "Expected a bounded native tool timeout")
    } catch let error as ShouError { try expect(error.code == "tool_timeout") }
    Thread.sleep(forTimeInterval: 1.3)
    try expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("escaped-child").path))
    try fixture.put(relative, "#!/bin/sh\n/usr/bin/yes 'bounded-output'\n")
    do {
        _ = try runner.run(.rustList, timeoutSeconds: 5)
        throw CheckFailure(description: "Expected a bounded native tool output failure")
    } catch let error as ShouError { try expect(error.code == "resource_limit") }
}
