import Foundation
import ShouCore
import ShouPlatform

private final class DockerStorageFixture: DockerStorageOperating, @unchecked Sendable {
    var objects: [DockerStorageObject] = [
        .init(kind: .container, objectId: String(repeating: "a", count: 64), name: "generated-stopped", bytes: nil, revision: "stopped-v1", state: "exited"),
        .init(kind: .container, objectId: String(repeating: "b", count: 64), name: "generated-running", bytes: nil, revision: "running-v1", state: "running"),
        .init(kind: .image, objectId: "sha256:" + String(repeating: "c", count: 64), name: "generated-unused:1", bytes: 4096, revision: "image-v1", state: "local"),
        .init(kind: .image, objectId: "sha256:" + String(repeating: "d", count: 64), name: "generated-used:1", bytes: 4096, revision: "image-v2", state: "local", references: 1),
        .init(kind: .volume, objectId: "generated_unused_volume", name: "generated_unused_volume", bytes: nil, revision: "volume-v1", state: "local"),
        .init(kind: .volume, objectId: "generated_referenced_volume", name: "generated_referenced_volume", bytes: nil, revision: "volume-v2", state: "local", references: 1),
        .init(kind: .buildCache, objectId: "unused-build-cache", name: "Unused build cache", bytes: 8192, revision: "cache-v1", state: "unused")
    ]
    var daemon="generated-daemon", endpoint="unix:///generated/docker.sock", executable="generated-docker-v1"
    var diskFingerprint="generated-disk-v1", allocated: Int64=16384
    var removed=[String](), reclaimed=0
    var failRemoval=false, failReclamation=false, diskSupported=true, referenceBeforeRemoval=false
    var onRemoval: (@Sendable () -> Void)?
    func contexts() throws -> [DockerStorageContext] { [.init(name: "generated-colima", endpoint: endpoint, current: true)] }
    func observe(context: String) throws -> DockerStorageInventory {
        .init(context: .init(name: context, endpoint: endpoint), daemonId: daemon, executableIdentity: executable, objects: objects,
            reclamation: diskSupported ? .init(profile: "generated", fingerprint: diskFingerprint, logicalBytes: 1048576, allocatedBytes: allocated, guestAvailableBytes: 524288) : nil)
    }
    func remove(_ object: DockerStorageObject, inventory: DockerStorageInventory, cacheBefore: Date) throws {
        if referenceBeforeRemoval { throw ShouError("source_changed", "Generated volume acquired a reference.") }
        guard try observe(context: inventory.context.name).sameBackend(as: inventory), objects.contains(object), object.blockingReason == nil else { throw ShouError("source_changed", "Generated selection changed.") }
        removed.append(object.id)
        if failRemoval { throw ShouError("tool_timeout", "Generated request result is unknown.") }
        objects.removeAll { $0.id == object.id }
        onRemoval?()
    }
    func reclaim(_ evidence: DockerDiskReclamation, inventory: DockerStorageInventory) throws -> DockerDiskReclamation {
        reclaimed += 1
        if failReclamation { throw ShouError("tool_timeout", "Generated TRIM result is unknown.") }
        guard evidence.fingerprint == diskFingerprint else { throw ShouError("source_changed", "Generated disk changed.") }
        allocated /= 2
        return .init(profile: "generated", fingerprint: diskFingerprint, logicalBytes: 1048576, allocatedBytes: allocated, guestAvailableBytes: 524288)
    }
    func availableBytes(inventory: DockerStorageInventory) -> Int64? { 1048576 - allocated }
}

func dockerStorageSeparatesExactObjectsVolumeConsentAndReclamation() async throws {
    let fixture=try Fixture(), platform=DockerStorageFixture(), service=DockerStorageService(platform: platform, store: fixture.store)
    let scan=try await service.scan(context: "generated-colima")
    try expect(scan.inventory.objects.filter { $0.blockingReason != nil }.count == 3)
    for blocked in scan.inventory.objects where blocked.blockingReason != nil {
        try await expectThrows { try await service.createPlan(scan: scan, objectIds: [blocked.id], reclaimDisk: false, volumeDataConsent: true) }
    }
    let selected=Set(scan.inventory.objects.filter { $0.blockingReason == nil }.map(\.id))
    try await expectThrows { try await service.createPlan(scan: scan, objectIds: selected, reclaimDisk: true) }
    let plan=try await service.createPlan(scan: scan, objectIds: selected, reclaimDisk: true, volumeDataConsent: true)
    let retention=try await ShouEngine(store: fixture.store, filesystem: fixture.fs).recordRetentionPreview(policy: .init(maxAgeSeconds: 0, maxBytes: 0, graceSeconds: 0, keepLatestScans: false))
    try expect(!retention.records.contains { $0.collection == "docker-storage-plans" || $0.collection == "docker-storage-scans" })
    let receipt=try await service.execute(plan)
    try expect(receipt.state == "completed" && receipt.items.allSatisfy { $0.state == "removed" })
    try expect(Set(platform.removed) == selected && platform.reclaimed == 1)
    try expect(platform.objects.count == 3 && platform.objects.allSatisfy { $0.blockingReason != nil })
    try expect(receipt.diskBefore?.logicalBytes == receipt.diskAfter?.logicalBytes && receipt.diskAfter?.allocatedBytes == 8192)
    try expect(receipt.volumeAvailableAfter! - receipt.volumeAvailableBefore! == 8192)
    try await expectThrows { try await service.execute(plan) }
}

func dockerStorageRejectsBackendChangesAndNeverReplaysUnknownRequests() async throws {
    let fixture=try Fixture(), platform=DockerStorageFixture(), service=DockerStorageService(platform: platform, store: fixture.store)
    let scan=try await service.scan(context: "generated-colima"), target=try require(scan.inventory.objects.first { $0.kind == .container && $0.blockingReason == nil })
    let plan=try await service.createPlan(scan: scan, objectIds: [target.id], reclaimDisk: true)
    platform.daemon="other-daemon"
    try await expectThrows { try await service.execute(plan) }
    try expect(platform.removed.isEmpty && platform.reclaimed == 0 && (try fixture.store.ids("docker-storage-intents")).isEmpty)
    platform.daemon="generated-daemon"; platform.failRemoval=true
    let result=try await service.execute(plan)
    try expect(result.state == "unknown" && result.items.first?.state == "unknown" && platform.reclaimed == 0)
    try expect(try fixture.store.ids("docker-storage-history") == [result.id])
    try await expectThrows { try await service.execute(plan) }
    try expect(platform.removed.count == 1)
    let interrupted=try Fixture(), guardedPlatform=DockerStorageFixture()
    let failedStore=JournalWriteStore(interrupted.store, failingCollection: "docker-storage-history", failingWrite: 1)
    let guarded=DockerStorageService(platform: guardedPlatform, store: failedStore)
    let initial=try await guarded.scan(context: "generated-colima")
    let frozen=try await guarded.createPlan(scan: initial, objectIds: [], reclaimDisk: true)
    try await expectThrows { try await guarded.execute(frozen) }
    try await expectThrows { try await guarded.execute(frozen) }
    try expect(guardedPlatform.removed.isEmpty && guardedPlatform.reclaimed == 0)
}

func dockerStorageReclamationIsIndependentAndUnsupportedBackendsStayClosed() async throws {
    let fixture=try Fixture(), platform=DockerStorageFixture(), service=DockerStorageService(platform: platform, store: fixture.store)
    let scan=try await service.scan(context: "generated-colima")
    try await expectThrows { try await service.createPlan(scan: scan, objectIds: [], reclaimDisk: false) }
    let plan=try await service.createPlan(scan: scan, objectIds: [], reclaimDisk: true)
    let result=try await service.execute(plan)
    try expect(result.state == "completed" && result.items.isEmpty && platform.removed.isEmpty && platform.reclaimed == 1)
    platform.diskSupported=false
    let unsupported=try await service.scan(context: "generated-colima")
    try await expectThrows { try await service.createPlan(scan: unsupported, objectIds: [], reclaimDisk: true) }
    platform.endpoint="tcp://generated-remote:2376"
    try await expectThrows { try await service.scan(context: "generated-colima") }
}

func dockerStorageDiskIdentityChangesAndUncertainTrimRemainRecorded() async throws {
    let fixture=try Fixture(), platform=DockerStorageFixture(), service=DockerStorageService(platform: platform, store: fixture.store)
    let scan=try await service.scan(context: "generated-colima")
    let plan=try await service.createPlan(scan: scan, objectIds: [], reclaimDisk: true)
    platform.diskFingerprint="replaced-generated-disk"
    try await expectThrows { try await service.execute(plan) }
    try expect(platform.reclaimed == 0)
    platform.diskFingerprint="generated-disk-v1"; platform.failReclamation=true
    let result=try await service.execute(plan)
    try expect(result.state == "unknown" && result.diskState == "unknown" && result.diskAfter == nil)
    try await expectThrows { try await service.execute(plan) }
    try expect(platform.reclaimed == 1 && platform.removed.isEmpty)
}

private final class DockerStorageClock: @unchecked Sendable {
    private let lock=NSLock()
    private var value=Date()
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(121) }
}

func dockerStorageExpiresBeforeDispatchWithoutInterruptingAnAuthorizedBatch() async throws {
    let fixture=try Fixture(), platform=DockerStorageFixture(), clock=DockerStorageClock()
    let service=DockerStorageService(platform: platform, store: fixture.store, now: { clock.read() })
    let scan=try await service.scan(context: "generated-colima")
    let ids=Set(scan.inventory.objects.filter { [.container, .image].contains($0.kind) && $0.blockingReason == nil }.map(\.id))
    let expired=try await service.createPlan(scan: scan, objectIds: ids, reclaimDisk: true)
    clock.advance()
    try await expectThrows { try await service.execute(expired) }
    try expect(platform.removed.isEmpty && (try fixture.store.ids("docker-storage-intents")).isEmpty)
    let current=try await service.scan(context: "generated-colima")
    let plan=try await service.createPlan(scan: current, objectIds: ids, reclaimDisk: true)
    platform.onRemoval={ clock.advance() }
    let result=try await service.execute(plan)
    try expect(result.state == "completed" && platform.removed.count == ids.count && platform.reclaimed == 1)
}

func nativeDockerRemovalCommandsKeepExactIdentitiesAndProtectVmDirectories() throws {
    let platform=DockerStorageFixture(), timestamp=Date(timeIntervalSince1970: 1800000000)
    for object in platform.objects where object.blockingReason == nil {
        let arguments=try NativeDockerStorage.removalArguments(object, cacheBefore: timestamp)
        if object.kind == .buildCache {
            try expect(arguments == ["builder", "prune", "--all", "--force", "--filter", "until=" + ISO8601DateFormatter().string(from: timestamp)])
        } else {
            try expect(arguments == [object.kind.rawValue, "rm", "--", object.objectId])
            try expect(!arguments.contains("--force") && !arguments.contains("--volumes"))
        }
    }
    let invalid=DockerStorageObject(kind: .volume, objectId: "--all", name: "invalid", bytes: nil, revision: "v1", state: "local")
    try expectThrows { try NativeDockerStorage.removalArguments(invalid, cacheBefore: timestamp) }
    let entry=FileEntry(path: ".colima", kind: "directory", device: 1, inode: 1, logicalBytes: 0, allocatedBytes: 0,
        modifiedNanoseconds: 0, changedNanoseconds: 0, mode: 0o700, owner: 501, links: 1)
    for path in [".colima", ".colima/_lima", ".docker", "Library/Containers/com.docker.docker"] {
        try expect(StorageRemovalPolicy.reason(root: "/Users/generated", path: path, entry: entry, home: "/Users/generated", protectedPaths: []) != nil)
    }
    try expect(StorageRemovalPolicy.reason(root: "/Users/generated", path: "generated-project", entry: entry, home: "/Users/generated", protectedPaths: []) == nil)
}
