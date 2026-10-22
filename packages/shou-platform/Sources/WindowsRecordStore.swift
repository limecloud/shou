#if os(Windows)
import Foundation
import ShouCore
import CShouWindows

public final class LocalRecordStore: RecordStore, @unchecked Sendable {
    public let directory: URL
    private let base: String
    public var protectedPaths: [String] { [base] }
    public static var defaultDirectory: URL {
        let env=ProcessInfo.processInfo.environment
        if let path=env["SHOU_DATA_DIR"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: env["LOCALAPPDATA"] ?? FileManager.default.homeDirectoryForCurrentUser.path).appendingPathComponent("Shou", isDirectory: true)
    }
    public init(directory: URL = LocalRecordStore.defaultDirectory) throws {
        self.base=try WindowsNative.string({ shou_win_normalize(directory.path, $0) }, path: directory.path)
        self.directory=URL(fileURLWithPath: base, isDirectory: true)
        try WindowsNative.check(shou_win_private_directory(base), path: base)
    }
    private func location(_ collection: String, id: String? = nil) throws -> String {
        for value in [collection] + (id.map { [$0] } ?? []) {
            guard value.range(of: "^[A-Za-z0-9_-]{1,120}$", options: .regularExpression) != nil else { throw ShouError("invalid_argument", "Invalid record identifier.") }
        }
        try WindowsNative.check(shou_win_private_directory(base), path: base)
        let folder=base + "/" + collection
        try WindowsNative.check(shou_win_private_directory(folder), path: folder)
        return id.map { folder + "/" + $0 + (collection == "storage-catalogs" ? ".sqlite" : collection == "ai-credentials" ? ".key" : ".json") } ?? folder
    }
    public func storageCatalogURL(id: String) throws -> URL? {
        let path=try location("storage-catalogs", id: id)
        do {
            let info=try WindowsNative.metadata(path)
            guard info.kind == 1, info.current_user == 1, info.links == 1 else {
                throw ShouError("store_corrupt", "Space analysis index has an invalid identity.", details: ["kind": String(info.kind), "current_user": String(info.current_user), "links": String(info.links)])
            }
        } catch let error as ShouError where error.code == "not_found" { }
        return URL(fileURLWithPath: path)
    }
    public func read(_ collection: String, id: String) throws -> Data? {
        let path=try location(collection, id: id)
        do { return try WindowsNative.read(path, limit: 268_435_456) }
        catch let error as ShouError where error.code == "not_found" { return nil }
    }
    public func write(_ collection: String, id: String, data: Data) throws {
        guard data.count <= 268_435_456 else { throw ShouError("resource_limit", "Record exceeds the storage limit.") }
        let path=try location(collection,id:id)
        try data.withUnsafeBytes { try WindowsNative.check(shou_win_write(path, $0.baseAddress, $0.count), path: path) }
    }
    func readAICredential(id: String) throws -> Data? {
        let path=try location("ai-credentials", id: id)
        do { return try WindowsNative.read(path, limit: 8192) }
        catch let error as ShouError where error.code == "not_found" { return nil }
    }
    func writeAICredential(id: String, data: Data) throws {
        guard data.count <= 8192 else { throw ShouError("invalid_ai_key", "Enter one API key no larger than 8 KiB.") }
        try write("ai-credentials", id: id, data: data)
    }
    public func ids(_ collection: String) throws -> [String] {
        let path=try location(collection)
        let text=try WindowsNative.string({ shou_win_list(path, 100_000, $0) }, path: path)
        return text.split(separator: "\n").map(String.init).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) }.sorted()
    }
    public func removeHistoryRecord(_ collection: String, id: String) throws {
        guard ["history", "followups", "history-manifests"].contains(collection) else { throw ShouError("invalid_argument", "Only history records can be removed here.") }
        let path=try location(collection, id: id)
        try WindowsNative.check(shou_win_remove_record(path), path: path)
    }
    public func records(_ collection: String) throws -> [StoredRecord] {
        let suffix=collection == "storage-catalogs" ? ".sqlite" : ".json"
        let path=try location(collection)
        let names=try WindowsNative.string({ shou_win_list(path, 100_000, $0) }, path: path)
        return try names.split(separator: "\n").map(String.init).filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }.compactMap { name in
            let id=String(name.dropLast(suffix.count))
            return try recordMetadata(collection, id: id)
        }
    }
    public func recordMetadata(_ collection: String, id: String) throws -> StoredRecord? {
        let path=try location(collection, id: id)
        let raw: shou_win_info
        do { raw=try WindowsNative.metadata(path) }
        catch let error as ShouError where error.code == "not_found" { return nil }
        guard raw.kind == 1, raw.current_user == 1, raw.links == 1 else { throw ShouError("store_corrupt", "Record metadata has an invalid identity.") }
        let info=WindowsNative.entry(raw, path: id)
        return StoredRecord(collection: collection, id: id, byteCount: info.logicalBytes,
            modifiedAt: Date(timeIntervalSince1970: Double(info.modifiedNanoseconds)/1e9), revision: try Digest.of(info))
    }
    public func removeDerivedRecord(_ record: StoredRecord) throws {
        guard DerivedRecords.collections.contains(record.collection) else { throw ShouError("invalid_argument", "Only derived Shou records can be collected.") }
        guard try recordMetadata(record.collection, id: record.id) == record else { throw ShouError("plan_stale", "The derived record changed before collection.") }
        try WindowsNative.check(shou_win_remove_record(try location(record.collection, id: record.id)), path: record.id)
    }
    public func lock() throws -> any StoreLease {
        try WindowsNative.check(shou_win_private_directory(directory.path), path: directory.path)
        var handle: OpaquePointer?
        try WindowsNative.check(shou_win_lock_acquire(directory.appendingPathComponent(".mutation.lock").path, &handle), path: directory.path)
        guard let handle else { throw ShouError("store_busy", "The record lock could not be acquired.") }
        return WindowsStoreLease(handle)
    }
}
private final class WindowsStoreLease: StoreLease, @unchecked Sendable {
    private let mutex=NSLock()
    private var handle: OpaquePointer?
    init(_ handle: OpaquePointer) { self.handle=handle }
    func release() { mutex.lock(); defer { mutex.unlock() }; if let handle { shou_win_lock_release(handle); self.handle=nil } }
    deinit { release() }
}
#endif
