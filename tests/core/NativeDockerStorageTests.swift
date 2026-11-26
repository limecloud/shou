import Foundation
import ShouCore
import ShouPlatform

/// Explicit generated-resource acceptance. Never starts a container, pulls an
/// image, touches an existing object or dispatches TRIM on a personal VM disk.
func nativeDockerStorageRemovesOnlyResourcesCreatedByThisRun() async throws {
    let fixture=try Fixture(), platform=NativeDockerStorage()
    let context=try require(try platform.contexts().first(where: \.current))
    let nonce=UUID().uuidString.lowercased(), name="shou-fixture-" + nonce, tag="shou-fixture:" + nonce
    var sequence=0
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        sequence += 1
        let output=fixture.base.appendingPathComponent("native-command-\(sequence).out")
        let diagnostic=fixture.base.appendingPathComponent("native-command-\(sequence).err")
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        _ = FileManager.default.createFile(atPath: diagnostic.path, contents: nil)
        let stdout=try FileHandle(forWritingTo: output), stderr=try FileHandle(forWritingTo: diagnostic)
        let process=Process(); process.executableURL=URL(fileURLWithPath: executable); process.arguments=arguments
        process.standardOutput=stdout; process.standardError=stderr; process.standardInput=FileHandle.nullDevice
        try process.run()
        let deadline=Date().addingTimeInterval(60)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw CheckFailure(description: "Generated Docker fixture command timed out; inspect the named fixture before continuing.") }
        try stdout.close(); try stderr.close()
        guard process.terminationStatus == 0 else { throw CheckFailure(description: "Generated Docker fixture command failed: " + (try String(contentsOf: diagnostic, encoding: .utf8))) }
        return try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let binary=FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/docker") ? "/opt/homebrew/bin/docker" : "/usr/local/bin/docker"
    func docker(_ arguments: [String]) throws -> String { try run(binary, ["--context", context.name] + arguments) }
    func ids(_ kind: String) throws -> Set<String> {
        let args=kind == "volume" ? ["volume", "ls", "--quiet"] : [kind, "ls", "--all", "--no-trunc", "--quiet"]
        return Set(try docker(args).split(whereSeparator: \.isWhitespace).map(String.init))
    }
    let beforeContainers=try ids("container"), beforeImages=try ids("image"), beforeVolumes=try ids("volume")
    try expect(!beforeVolumes.contains(name))
    try fixture.put("rootfs/fixture.txt", "Generated Docker storage acceptance; no personal data.")
    let archive=fixture.base.appendingPathComponent("generated-rootfs.tar")
    _ = try run("/usr/bin/tar", ["-cf", archive.path, "-C", fixture.workspace.appendingPathComponent("rootfs").path, "fixture.txt"])
    let image=try docker(["image", "import", archive.path, tag])
    try expect(!beforeImages.contains(image))
    let volume=try docker(["volume", "create", "--label", "shou.generated-fixture=" + nonce, name])
    try expect(volume == name && image.hasPrefix("sha256:"))
    let container=try docker(["container", "create", "--name", name, "--label", "shou.generated-fixture=" + nonce,
        "--mount", "type=volume,source=" + name + ",target=/fixture", tag, "/bin/true"])
    try expect(!beforeContainers.contains(container))
    print("Generated Docker acceptance owns only container \(container), volume \(name), image \(image); it never starts them.")
    let service=DockerStorageService(platform: platform, store: fixture.store)
    let first=try await service.scan(context: context.name)
    let containerObject=try require(first.inventory.objects.first { $0.kind == .container && $0.objectId == container && $0.name == name })
    let volumeObject=try require(first.inventory.objects.first { $0.kind == .volume && $0.objectId == name })
    let imageObject=try require(first.inventory.objects.first { $0.kind == .image && $0.objectId == image })
    try expect(containerObject.state == "created" && containerObject.blockingReason == nil)
    try expect(volumeObject.references == 1 && volumeObject.blockingReason != nil && imageObject.blockingReason != nil)
    try await expectThrows { try await service.createPlan(scan: first, objectIds: [volumeObject.id], reclaimDisk: false, volumeDataConsent: true) }
    let containerPlan=try await service.createPlan(scan: first, objectIds: [containerObject.id], reclaimDisk: false)
    let removedContainer=try await service.execute(containerPlan)
    try expect(removedContainer.state == "completed")
    let second=try await service.scan(context: context.name)
    let remaining=second.inventory.objects.filter { ($0.kind == .volume && $0.objectId == name) || ($0.kind == .image && $0.objectId == image) }
    try expect(remaining.count == 2 && remaining.allSatisfy { $0.blockingReason == nil })
    let dataPlan=try await service.createPlan(scan: second, objectIds: Set(remaining.map(\.id)), reclaimDisk: false, volumeDataConsent: true)
    let removedData=try await service.execute(dataPlan)
    try expect(removedData.state == "completed" && removedData.items.count == 2)
    try await expectThrows { try await service.execute(containerPlan) }
    try await expectThrows { try await service.execute(dataPlan) }
    try expect(try ids("container") == beforeContainers && ids("image") == beforeImages && ids("volume") == beforeVolumes)
    print("Native Docker acceptance passed: exact generated container/image/volume removal, live mount-reference refusal, data consent and replay protection. All pre-existing object IDs remain; no TRIM dispatched.")
}
