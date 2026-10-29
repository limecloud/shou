import Foundation

/// Plans keep small mutable metadata separate from their immutable manifests.
/// Legacy inline plans remain readable; no existing user record is rewritten.
enum StorageRemovalPlanRecords {
    struct Loaded {
        let plan: StorageRemovalPlan
        let sources: [FileManifestSource]
    }
    private struct Manifest: Codable {
        let count: Int
        let pages: [FileManifestPage]
    }
    private struct Record: Codable {
        let formatVersion: Int
        var plan: StorageRemovalPlan
        let manifests: [Manifest]
        func digest() throws -> String {
            var copy=self
            copy.plan.digest=""; copy.plan.state="ready"
            return try Digest.of(copy)
        }
    }

    private static func record(_ plan: StorageRemovalPlan,
                               consume: (FileManifestPage, Data) throws -> Void = { _, _ in }) throws -> Record {
        var compact=plan, manifests=[Manifest]()
        compact.items=[]
        for (index, item) in plan.items.enumerated() {
            let pages=try FileManifestRecords.pages(item.manifest, prefix: plan.id + "_" + String(index), checkpoint: {
                if Task.isCancelled { throw ShouError("cancelled", "Selection review stopped.") }
            }, consume: consume)
            manifests.append(Manifest(count: item.manifest.count, pages: pages))
            compact.items.append(StorageRemovalItem(path: item.path, manifest: [], allocatedBytesEstimate: item.allocatedBytesEstimate))
        }
        return Record(formatVersion: 1, plan: compact, manifests: manifests)
    }

    static func digest(_ plan: StorageRemovalPlan) throws -> String { try record(plan).digest() }

    static func save(_ plan: inout StorageRemovalPlan, store: any RecordStore,
                     progress: (String) -> Void) throws {
        plan.manifestFormatVersion=1
        let rootPath=plan.rootPath
        var value=try record(plan) { page, data in
            try store.write("storage-plan-manifests", id: page.id, data: data)
            progress(rootPath)
        }
        plan.digest=try value.digest()
        value.plan.digest=plan.digest
        if Task.isCancelled { throw ShouError("cancelled", "Selection review stopped.") }
        try store.write("storage-plans", id: plan.id, data: Codec.encode(value))
    }

    static func load(_ id: String, store: any RecordStore) throws -> StorageRemovalPlan {
        try loadWithSources(id, store: store).plan
    }

    static func loadWithSources(_ id: String, store: any RecordStore) throws -> Loaded {
        guard let data=try store.read("storage-plans", id: id) else { throw ShouError("invalid_argument", "Unknown space removal plan.") }
        struct Header: Decodable { let formatVersion: Int?; let plan: StorageRemovalPlan? }
        let header=try Codec.decode(Header.self, from: data)
        guard header.formatVersion != nil || header.plan != nil else {
            let plan=try Codec.decode(StorageRemovalPlan.self, from: data)
            guard plan.id == id, plan.manifestFormatVersion == nil, try plan.calculatedDigest() == plan.digest else { throw FileManifestRecords.corrupt() }
            return Loaded(plan: plan, sources: [])
        }
        let value=try Codec.decode(Record.self, from: data)
        guard value.formatVersion == 1, value.plan.manifestFormatVersion == 1, value.plan.id == id,
              value.plan.items.count == value.manifests.count, (1...5000).contains(value.plan.items.count),
              try value.digest() == value.plan.digest else { throw FileManifestRecords.corrupt() }
        var plan=value.plan, sources=[FileManifestSource]()
        for (index, item) in plan.items.enumerated() {
            guard item.manifest.isEmpty else { throw FileManifestRecords.corrupt() }
            let manifest=value.manifests[index]
            let entries=try FileManifestRecords.load(manifest.pages, count: manifest.count, prefix: id + "_" + String(index), collection: "storage-plan-manifests", store: store, checkpoint: {
                if Task.isCancelled { throw ShouError("cancelled", "Selection review stopped.") }
            })
            plan.items[index]=StorageRemovalItem(path: item.path, manifest: entries, allocatedBytesEstimate: item.allocatedBytesEstimate)
            sources.append(FileManifestSource(entries: entries, pages: manifest.pages, prefix: id + "_" + String(index), collection: "storage-plan-manifests"))
        }
        return Loaded(plan: plan, sources: sources)
    }

    static func updateState(_ plan: StorageRemovalPlan, store: any RecordStore, state: String = "executing") throws {
        guard plan.manifestFormatVersion == 1 else {
            var copy=plan; copy.state=state
            try store.write("storage-plans", id: copy.id, data: Codec.encode(copy)); return
        }
        guard let data=try store.read("storage-plans", id: plan.id) else { throw FileManifestRecords.corrupt() }
        var value=try Codec.decode(Record.self, from: data)
        guard value.plan.id == plan.id, value.plan.state == (state == "executing" ? "ready" : "executing"), value.plan.digest == plan.digest,
              try value.digest() == plan.digest else { throw FileManifestRecords.corrupt() }
        value.plan.state=state
        try store.write("storage-plans", id: plan.id, data: Codec.encode(value))
    }
}
