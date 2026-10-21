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
        return id.map { folder + "/" + $0 + ".json" } ?? folder
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
        // Windows currently persists JSON evidence rather than SQLite catalogs.
        if collection == "storage-catalogs" { return [] }
        return try ids(collection).compactMap { id in
            try recordMetadata(collection, id: id)
        }
    }
    public func recordMetadata(_ collection: String, id: String) throws -> StoredRecord? {
        if collection == "storage-catalogs" { return nil }
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
        guard DerivedRecords.collections.contains(record.collection), record.collection != "storage-catalogs" else { throw ShouError("invalid_argument", "Only derived Shou records can be collected.") }
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
