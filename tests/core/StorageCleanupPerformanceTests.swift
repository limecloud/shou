import Foundation
import ShouCore
import ShouPlatform

/// The workload is generated afresh for each run; no personal directory is used.
func storageCleanupPipelineBenchmark() async throws {
    let fixture=try Fixture()
    let tail=Array(repeating: "nested", count: 12).joined(separator: "/")
    for name in ["generated-a", "generated-b"] {
        let directory=fixture.workspace.appendingPathComponent(name + "/" + tail)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<10_000 { try Data("generated".utf8).write(to: directory.appendingPathComponent("file-\(index).bin")) }
    }
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let started=ProcessInfo.processInfo.systemUptime
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let scanned=ProcessInfo.processInfo.systemUptime
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["generated-a", "generated-b"], action: "permanent")
    let prepared=ProcessInfo.processInfo.systemUptime
    let planBytes=try require(fixture.store.read("storage-plans", id: plan.id)).count
    let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-benchmark")
    let finished=ProcessInfo.processInfo.systemUptime
    try expect(receipt.state == "completed" && receipt.items.allSatisfy { $0.state == "purged" })
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
    let records=try ["storage-plans", "storage-plan-manifests", "history", "history-manifests"].flatMap { try fixture.store.records($0) }
    let report: [String: JSONValue]=[
        "entries": .integer(Int64(plan.items.reduce(0) { $0 + $1.manifest.count })),
        "scan_seconds": .number(scanned - started), "prepare_seconds": .number(prepared - scanned),
        "execute_seconds": .number(finished - prepared), "total_seconds": .number(finished - started),
        "plan_bytes": .integer(Int64(planBytes)), "maximum_record_bytes": .integer(records.map(\.byteCount).max() ?? 0)
    ]
    print("storage-cleanup-benchmark " + String(decoding: try Codec.encode(report), as: UTF8.self))
}
