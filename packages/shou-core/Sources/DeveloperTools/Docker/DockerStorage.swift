import Foundation

public enum DockerStorageLocations {
    public static func protectedPaths(home: String) -> [String] {
        [home + "/.colima", home + "/.docker", home + "/Library/Containers/com.docker.docker", home + "/Library/Group Containers/group.com.docker"]
    }
}

public struct DockerStorageContext: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let endpoint: String
    public let current: Bool
    public init(name: String, endpoint: String, current: Bool = false) { self.name=name; self.endpoint=endpoint; self.current=current }
}

public enum DockerStorageKind: String, Codable, Sendable { case buildCache, container, image, volume }

public struct DockerStorageObject: Codable, Sendable, Equatable, Identifiable {
    public var id: String { kind.rawValue + ":" + objectId }
    public let kind: DockerStorageKind
    public let objectId: String
    public let name: String
    public let bytes: Int64?
    public let revision: String
    public let state: String
    public let references: Int
    public init(kind: DockerStorageKind, objectId: String, name: String, bytes: Int64?, revision: String, state: String, references: Int = 0) {
        self.kind=kind; self.objectId=objectId; self.name=name; self.bytes=bytes; self.revision=revision; self.state=state; self.references=references
    }
    public var blockingReason: String? {
        if references > 0 { return "Referenced by a container" }
        switch kind {
        case .container: return ["exited", "created", "dead"].contains(state) ? nil : "Running containers are kept"
        case .volume: return state == "local" ? nil : "Only ordinary local volumes are supported"
        case .image: return state == "local" ? nil : state == "multiple_tags" ? "Images with multiple tags are kept" : "Image identity could not be verified"
        case .buildCache: return state == "unused" && (bytes ?? 0) > 0 ? nil : "No unused build cache"
        }
    }
}

public struct DockerDiskReclamation: Codable, Sendable, Equatable {
    public let profile: String
    public let fingerprint: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let guestAvailableBytes: Int64
    public init(profile: String, fingerprint: String, logicalBytes: Int64, allocatedBytes: Int64, guestAvailableBytes: Int64) {
        self.profile=profile; self.fingerprint=fingerprint; self.logicalBytes=logicalBytes; self.allocatedBytes=allocatedBytes; self.guestAvailableBytes=guestAvailableBytes
    }
}

public struct DockerStorageInventory: Codable, Sendable {
    public let context: DockerStorageContext
    public let daemonId: String
    public let executableIdentity: String
    public let objects: [DockerStorageObject]
    public let reclamation: DockerDiskReclamation?
    public let reclamationIssue: String?
    public init(context: DockerStorageContext, daemonId: String, executableIdentity: String, objects: [DockerStorageObject], reclamation: DockerDiskReclamation? = nil, reclamationIssue: String? = nil) {
        self.context=context; self.daemonId=daemonId; self.executableIdentity=executableIdentity; self.objects=objects; self.reclamation=reclamation; self.reclamationIssue=reclamationIssue
    }
    public func sameBackend(as other: Self) -> Bool {
        context.name == other.context.name && context.endpoint == other.context.endpoint && daemonId == other.daemonId && executableIdentity == other.executableIdentity
    }
}

/// The platform owns fixed owner commands. No imported rule supplies a shell,
/// executable, mount point, disk path, container image or command-line option.
public protocol DockerStorageOperating: Sendable {
    func contexts() throws -> [DockerStorageContext]
    func observe(context: String) throws -> DockerStorageInventory
    /// Rechecks this exact object and backend, uses a non-forced owner operation,
    /// and verifies absence. It must never expand to newly discovered objects.
    func remove(_ object: DockerStorageObject, inventory: DockerStorageInventory, cacheBefore: Date) throws
    func reclaim(_ evidence: DockerDiskReclamation, inventory: DockerStorageInventory) throws -> DockerDiskReclamation
    func availableBytes(inventory: DockerStorageInventory) -> Int64?
}

public struct DockerStorageScan: Codable, Sendable {
    public let id: String
    public let createdAt: Date
    public let inventory: DockerStorageInventory
}
public struct DockerStoragePlan: Codable, Sendable {
    public let id: String
    public let scan: DockerStorageScan
    public let objects: [DockerStorageObject]
    public let reclaimDisk: Bool
    public let expiresAt: Date
    public var digest: String
    public func calculatedDigest() throws -> String { var value=self; value.digest=""; return try Digest.of(value) }
}
public struct DockerStorageItemResult: Codable, Sendable, Identifiable {
    public var id: String { object.id }
    public let object: DockerStorageObject
    public var state: String
    public var error: String?
}
public struct DockerStorageReceipt: Codable, Sendable, Identifiable {
    public let id: String
    public let planId: String
    public let context: String
    public var state: String
    public var items: [DockerStorageItemResult]
    public var diskBefore: DockerDiskReclamation?
    public var diskAfter: DockerDiskReclamation?
    public var diskState: String?
    public var error: String?
    public var volumeAvailableBefore: Int64?
    public var volumeAvailableAfter: Int64?
}

public actor DockerStorageService {
    private let platform: any DockerStorageOperating
    private let store: any RecordStore
    private let now: @Sendable () -> Date
    public init(platform: any DockerStorageOperating, store: any RecordStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.platform=platform; self.store=store; self.now=now
    }
    public func contexts() throws -> [DockerStorageContext] { try platform.contexts() }
    public func scan(context: String) throws -> DockerStorageScan {
        let inventory=try platform.observe(context: context)
        guard inventory.context.endpoint.hasPrefix("unix:///"), !inventory.daemonId.isEmpty,
              !inventory.executableIdentity.isEmpty, inventory.objects.count <= 5000,
              Set(inventory.objects.map(\.id)).count == inventory.objects.count,
              inventory.objects.allSatisfy({ $0.references >= 0 && ($0.bytes ?? 0) >= 0 }) else {
            throw ShouError("unsupported_schema", "Docker returned an unsupported local inventory.")
        }
        let scan=DockerStorageScan(id: Codec.id("dockerscan"), createdAt: now(), inventory: inventory)
        try store.write("docker-storage-scans", id: scan.id, data: Codec.encode(scan))
        return scan
    }
    public func createPlan(scan: DockerStorageScan, objectIds: Set<String>, reclaimDisk: Bool, volumeDataConsent: Bool = false) throws -> DockerStoragePlan {
        guard now().timeIntervalSince(scan.createdAt) < 600,
              let saved=try store.read("docker-storage-scans", id: scan.id), saved == (try Codec.encode(scan)),
              !objectIds.isEmpty || reclaimDisk else { throw ShouError("plan_stale", "Check Docker storage and select the exact objects again.") }
        let objects=scan.inventory.objects.filter { objectIds.contains($0.id) }
        guard objects.count == objectIds.count, objects.allSatisfy({ $0.blockingReason == nil }),
              !objects.contains(where: { $0.kind == .volume }) || volumeDataConsent,
              !reclaimDisk || scan.inventory.reclamation != nil else { throw ShouError("confirmation_required", "Review Docker objects, volume data and disk reclamation separately.") }
        var plan=DockerStoragePlan(id: Codec.id("dockerplan"), scan: scan, objects: objects, reclaimDisk: reclaimDisk,
            expiresAt: now().addingTimeInterval(120), digest: "")
        plan.digest=try plan.calculatedDigest()
        try store.write("docker-storage-plans", id: plan.id, data: Codec.encode(plan))
        return plan
    }
    public func execute(_ reviewed: DockerStoragePlan) throws -> DockerStorageReceipt {
        let lease=try store.lock(); defer { lease.release() }
        guard let data=try store.read("docker-storage-plans", id: reviewed.id), data == (try Codec.encode(reviewed)),
              reviewed.digest == (try reviewed.calculatedDigest()), reviewed.expiresAt > now(),
              try store.read("docker-storage-intents", id: reviewed.id) == nil else { throw ShouError("confirmation_required", "Docker cleanup expired, changed or was already started.") }
        let initial=try platform.observe(context: reviewed.scan.inventory.context.name)
        guard initial.sameBackend(as: reviewed.scan.inventory), reviewed.objects.allSatisfy({ object in initial.objects.contains { $0 == object && $0.blockingReason == nil } }),
              !reviewed.reclaimDisk || initial.reclamation?.fingerprint == reviewed.scan.inventory.reclamation?.fingerprint else {
            throw ShouError("plan_stale", "Docker objects or the backend changed. Review storage again.")
        }
        guard reviewed.expiresAt > now(), !Task.isCancelled else { throw ShouError("confirmation_required", "Docker cleanup expired before execution started.") }
        var receipt=DockerStorageReceipt(id: Codec.id("dockerrun"), planId: reviewed.id, context: initial.context.name, state: "executing",
            items: reviewed.objects.map { .init(object: $0, state: "pending") }, diskBefore: initial.reclamation,
            volumeAvailableBefore: platform.availableBytes(inventory: initial))
        // An immutable intent prevents replay even if a later journal write fails.
        // Consume the short-lived confirmation once at dispatch. A fixed batch
        // may outlast its review period; each object still gets live owner checks.
        try store.write("docker-storage-intents", id: reviewed.id, data: Codec.encode(receipt.id))
        func save() throws { try store.write("docker-storage-history", id: receipt.id, data: Codec.encode(receipt)) }
        try save()
        for index in receipt.items.indices {
            if Task.isCancelled { receipt.state="cancelled"; break }
            do {
                let object=receipt.items[index].object
                receipt.items[index].state="removing"; try save()
                try platform.remove(object, inventory: initial, cacheBefore: reviewed.scan.createdAt)
                receipt.items[index].state="removed"; try save()
            } catch {
                if receipt.items[index].state == "removing" {
                    receipt.items[index].state="unknown"; receipt.state="unknown"
                } else { receipt.items[index].state="skipped"; receipt.state="partial" }
                receipt.items[index].error=(error as? ShouError)?.code ?? "tool_failed"
                try save(); break
            }
        }
        if reviewed.reclaimDisk && receipt.state == "executing" && receipt.items.allSatisfy({ $0.state == "removed" }) {
            do {
                guard !Task.isCancelled else { throw ShouError("cancelled", "Disk reclamation did not start.") }
                let current=try platform.observe(context: initial.context.name)
                guard current.sameBackend(as: initial), let evidence=current.reclamation,
                      evidence.fingerprint == initial.reclamation?.fingerprint else { throw ShouError("plan_stale", "The virtual disk changed before reclamation.") }
                receipt.diskBefore=evidence; receipt.diskState="reclaiming"; try save()
                receipt.diskAfter=try platform.reclaim(evidence, inventory: current)
                receipt.diskState="completed"; try save()
            } catch {
                receipt.diskState=receipt.diskState == "reclaiming" ? "unknown" : "skipped"
                receipt.state=receipt.diskState == "unknown" ? "unknown" : "partial"
                receipt.error=(error as? ShouError)?.code ?? "tool_failed"; try save()
            }
        }
        if receipt.state == "executing" { receipt.state=receipt.items.allSatisfy { $0.state == "removed" } ? "completed" : "partial" }
        receipt.volumeAvailableAfter=platform.availableBytes(inventory: initial); try save()
        return receipt
    }
}
