import Foundation
import CSQLite

private final class CatalogCheckpoint {
    let check: () throws -> Void
    var error: (any Error)?
    init(_ check: @escaping () throws -> Void) { self.check=check }
}

private final class CatalogMapDirectories { var ids=Set<Int64>() }

public struct StorageMeasurement: Sendable {
    public let tree: TreeSnapshot
    public let entryCount: Int
    public init(tree: TreeSnapshot, entryCount: Int) { self.tree=tree; self.entryCount=entryCount }
}

public struct StorageCatalogItem: Codable, Sendable {
    public let entry: FileEntry
    public var node: StorageNode
    public init(entry: FileEntry, node: StorageNode) { self.entry=entry; self.node=node }
}

public struct StorageDirectory: Sendable {
    public let item: StorageCatalogItem
    public let children: [StorageCatalogItem]
}

/// One immutable, disk-backed index per analysis. Measurement streams rows here;
/// readers fetch one directory, never a full-disk deletion manifest.
public final class StorageCatalog {
    private var database: OpaquePointer?
    private var insert: OpaquePointer?
    private var update: OpaquePointer?
    private var hardLink: OpaquePointer?
    private var parentLookup: OpaquePointer?
    private let writable: Bool
    private var schemaVersion: Int32 = 2
    private var cachedParent: (path: String, id: Int64)?
    private let transient=unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL, create: Bool = false, prepareNewFile: () throws -> Void = {}) throws {
        writable=create
        guard !create || !FileManager.default.fileExists(atPath: url.path) else { throw Self.failure() }
        // Platforms can exclusively create the empty file with native ownership
        // after the existing-file check and before SQLite opens it.
        if create { try prepareNewFile() }
        let flags=(create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database=nil
            throw Self.failure()
        }
        do {
            try execute("PRAGMA trusted_schema=OFF; PRAGMA cache_size=-8192; PRAGMA mmap_size=0;")
            if create {
                #if !os(Windows)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                #endif
                // A killed scan is never published. The final transaction and
                // metadata are durable before the engine publishes its record.
                try execute("PRAGMA journal_mode=OFF; PRAGMA synchronous=FULL; PRAGMA page_size=4096; PRAGMA max_page_count=1048576; PRAGMA user_version=2;")
                // Full paths are stored once per directory. File rows keep only
                // their name and parent ID, avoiding gigabytes of repeated prefixes.
                try execute("CREATE TABLE entries(id INTEGER PRIMARY KEY,path TEXT,parent INTEGER NOT NULL,name TEXT NOT NULL,kind TEXT NOT NULL,device INTEGER,inode INTEGER,logical INTEGER,allocated INTEGER,modified INTEGER,changed INTEGER,mode INTEGER,owner INTEGER,links INTEGER,total_logical INTEGER,total_allocated INTEGER,files INTEGER,newest INTEGER,complete INTEGER,windows_volume INTEGER,windows_file_id TEXT,windows_owner_sid TEXT); CREATE UNIQUE INDEX directories ON entries(path) WHERE path IS NOT NULL;")
                // Index only substantial files. Tiny build/cache entries dominate
                // disk inventories; they should not be revisited on every page.
                try execute("CREATE INDEX large_files ON entries(total_allocated DESC,name,parent) WHERE kind='file' AND total_allocated>=1048576;")
                try execute("CREATE INDEX measurement_directories ON entries(parent,name) WHERE kind='directory';")
                try execute("CREATE TABLE hard_links(identity TEXT PRIMARY KEY) WITHOUT ROWID; BEGIN IMMEDIATE;")
                insert=try prepare("INSERT INTO entries(path,parent,name,kind,device,inode,logical,allocated,modified,changed,mode,owner,links,total_logical,total_allocated,files,newest,complete,windows_volume,windows_file_id,windows_owner_sid) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
                update=try prepare("UPDATE entries SET total_logical=?,total_allocated=?,files=?,newest=?,complete=? WHERE id=?")
                hardLink=try prepare("INSERT OR IGNORE INTO hard_links VALUES(?)")
                parentLookup=try prepare("SELECT id FROM entries WHERE path=?")
            } else {
                try execute("PRAGMA query_only=ON;")
                let version=try prepare("PRAGMA user_version")
                defer { sqlite3_finalize(version) }
                guard sqlite3_step(version) == SQLITE_ROW else { throw Self.failure() }
                schemaVersion=sqlite3_column_int(version, 0)
                guard [1, 2].contains(schemaVersion) else { throw Self.failure() }
            }
        } catch { close(); throw error }
    }
    deinit { close() }
    private func close() {
        sqlite3_finalize(insert); insert=nil
        sqlite3_finalize(update); update=nil
        sqlite3_finalize(hardLink); hardLink=nil
        sqlite3_finalize(parentLookup); parentLookup=nil
        if let database { sqlite3_close(database) }; database=nil
    }
    private static func failure() -> ShouError { ShouError("store_corrupt", "Space analysis index is unavailable or inconsistent.") }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Self.failure() }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Self.failure() }
        return statement
    }
    private func bind(_ value: String, _ index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else { throw Self.failure() }
    }
    private func bind(_ values: [Int64], startingAt start: Int32, to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_int64(statement, start + Int32(index), value) == SQLITE_OK else { throw Self.failure() }
        }
    }
    private func finish(_ statement: OpaquePointer) throws {
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.failure() }
    }
    /// Only multiply-linked files need a deduplication set. It stays on disk.
    public func append(_ entry: FileEntry, complete: Bool? = nil) throws -> StorageNode {
        let parentID=entry.path == "." ? 0 : try directoryID(StorageIndex.parent(entry.path))
        let name=entry.path.lastIndex(of: "/").map { String(entry.path[entry.path.index(after: $0)...]) } ?? entry.path
        return try append(entry, name: name, parentID: parentID, complete: complete).node
    }
    private func directoryID(_ path: String) throws -> Int64 {
        if cachedParent?.path == path { return cachedParent!.id }
        guard let parentLookup else { throw Self.failure() }
        defer { sqlite3_reset(parentLookup); sqlite3_clear_bindings(parentLookup) }
        try bind(path, 1, to: parentLookup)
        guard sqlite3_step(parentLookup) == SQLITE_ROW else { throw Self.failure() }
        let id=sqlite3_column_int64(parentLookup, 0)
        cachedParent=(path, id)
        return id
    }
    /// Traversal already knows the parent and basename. Reuse them instead of
    /// splitting every full path and resolving its parent through SQLite.
    public func append(_ entry: FileEntry, name: String, parentID: Int64, complete: Bool? = nil) throws -> (id: Int64, node: StorageNode) {
        guard writable, let insert else { throw Self.failure() }
        if let identity=entry.windowsIdentity { try Self.validate(identity) }
        var charged=entry.kind != "symlink" && entry.kind != "special"
        if charged && entry.kind == "file" && entry.links > 1, let hardLink {
            try bind(entry.objectIdentityKey, 1, to: hardLink)
            try finish(hardLink)
            charged=sqlite3_changes(database) == 1
        }
        var node=StorageNode(path: entry.path, kind: entry.kind,
            logicalBytes: charged ? entry.logicalBytes : 0, allocatedBytes: charged ? entry.allocatedBytes : 0,
            fileCount: entry.kind == "file" ? 1 : 0, newestModifiedNanoseconds: entry.modifiedNanoseconds)
        node.isComplete=complete ?? (entry.kind != "directory")
        if entry.kind == "directory" { try bind(entry.path, 1, to: insert) }
        else { sqlite3_bind_null(insert, 1) }
        try bind([parentID], startingAt: 2, to: insert)
        try bind(name, 3, to: insert)
        try bind(entry.kind, 4, to: insert)
        try bind([Int64(bitPattern: entry.device), Int64(bitPattern: entry.inode), entry.logicalBytes, entry.allocatedBytes,
                  entry.modifiedNanoseconds, entry.changedNanoseconds, Int64(entry.mode), Int64(entry.owner), Int64(bitPattern: entry.links),
                  node.logicalBytes, node.allocatedBytes, Int64(node.fileCount), node.newestModifiedNanoseconds, node.isComplete == true ? 1 : 0], startingAt: 5, to: insert)
        if let identity=entry.windowsIdentity {
            try bind([Int64(bitPattern: identity.volume)], startingAt: 19, to: insert)
            try bind(identity.fileId, 20, to: insert)
            try bind(identity.ownerSid, 21, to: insert)
        } else {
            for column: Int32 in 19...21 { sqlite3_bind_null(insert, column) }
        }
        try finish(insert)
        return (sqlite3_last_insert_rowid(database), node)
    }
    public func setTotals(_ node: StorageNode) throws {
        try setTotals(node, id: directoryID(node.path))
    }
    public func setTotals(_ node: StorageNode, id: Int64) throws {
        guard writable, let update else { throw Self.failure() }
        try bind([node.logicalBytes, node.allocatedBytes, Int64(node.fileCount), node.newestModifiedNanoseconds, node.isComplete == true ? 1 : 0], startingAt: 1, to: update)
        try bind([id], startingAt: 6, to: update)
        try finish(update)
    }
    public func seal(checkpoint: () throws -> Void = {}) throws {
        try seal(progress: { _, _ in }, checkpoint: checkpoint)
    }
    public func seal(progress: (Int, Int) -> Void, checkpoint: () throws -> Void = {}) throws {
        try checkpoint()
        let steps=["COMMIT;", "CREATE UNIQUE INDEX children ON entries(parent,name); CREATE INDEX child_sizes ON entries(parent,total_allocated DESC,name);", "DROP TABLE hard_links; DROP INDEX measurement_directories;", "PRAGMA optimize;"]
        progress(0, steps.count)
        try withoutActuallyEscaping(checkpoint) { callback in
            let context=CatalogCheckpoint(callback)
            sqlite3_progress_handler(database, 4096, { pointer in
                guard let pointer else { return 1 }
                let context=Unmanaged<CatalogCheckpoint>.fromOpaque(pointer).takeUnretainedValue()
                do { try context.check(); return 0 }
                catch { context.error=error; return 1 }
            }, Unmanaged.passUnretained(context).toOpaque())
            defer { sqlite3_progress_handler(database, 0, nil, nil) }
            do {
                for (index, statement) in steps.enumerated() {
                    try checkpoint()
                    try execute(statement)
                    try checkpoint()
                    progress(index + 1, steps.count)
                }
            }
            catch { throw context.error ?? error }
        }
        try checkpoint()
    }
    private static let pathColumn="COALESCE(e.path,CASE WHEN d.path='.' THEN e.name ELSE d.path||'/'||e.name END)"
    private static let columns=pathColumn + ",e.kind,e.device,e.inode,e.logical,e.allocated,e.modified,e.changed,e.mode,e.owner,e.links,e.total_logical,e.total_allocated,e.files,e.newest,e.complete"
    private var columns: String { Self.columns + (schemaVersion == 2 ? ",e.windows_volume,e.windows_file_id,e.windows_owner_sid" : ",NULL,NULL,NULL") }
    private static let source=" FROM entries e LEFT JOIN entries d ON d.id=e.parent "
    private static func validate(_ identity: WindowsFileIdentity) throws {
        guard identity.fileId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              identity.ownerSid.utf8.count < 192,
              identity.ownerSid.range(of: "^S-1-[0-9]+(-[0-9]+)+$", options: .regularExpression) != nil else { throw failure() }
    }
    private func item(_ statement: OpaquePointer) throws -> StorageCatalogItem {
        guard let pathBytes=sqlite3_column_text(statement, 0), let kindBytes=sqlite3_column_text(statement, 1) else { throw Self.failure() }
        let path=String(cString: pathBytes), kind=String(cString: kindBytes)
        guard (path == "." || StorageRemovalPolicy.validRelative(path)), ["directory", "file", "symlink", "special"].contains(kind) else { throw Self.failure() }
        func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        guard (4...5).allSatisfy({ integer(Int32($0)) >= 0 }), (11...13).allSatisfy({ integer(Int32($0)) >= 0 }),
              (0...Int64(UInt32.max)).contains(integer(8)), (0...Int64(UInt32.max)).contains(integer(9)) else { throw Self.failure() }
        var entry=FileEntry(path: path, kind: kind, device: UInt64(bitPattern: integer(2)), inode: UInt64(bitPattern: integer(3)),
            logicalBytes: integer(4), allocatedBytes: integer(5), modifiedNanoseconds: integer(6), changedNanoseconds: integer(7),
            mode: UInt32(integer(8)), owner: UInt32(integer(9)), links: UInt64(bitPattern: integer(10)))
        let windowsColumns=(16...18).map { sqlite3_column_type(statement, Int32($0)) != SQLITE_NULL }
        if windowsColumns.contains(true) {
            guard windowsColumns.allSatisfy({ $0 }), let fileID=sqlite3_column_text(statement, 17), let sid=sqlite3_column_text(statement, 18) else { throw Self.failure() }
            let identity=WindowsFileIdentity(volume: UInt64(bitPattern: integer(16)), fileId: String(cString: fileID), ownerSid: String(cString: sid))
            try Self.validate(identity); entry.windowsIdentity=identity
        }
        var node=StorageNode(path: path, kind: kind, logicalBytes: integer(11), allocatedBytes: integer(12), fileCount: Int(integer(13)), newestModifiedNanoseconds: integer(14))
        node.isComplete=integer(15) == 1
        return StorageCatalogItem(entry: entry, node: node)
    }
    public func entry(at path: String) throws -> StorageCatalogItem? {
        let statement=try prepare("SELECT " + columns + Self.source + "WHERE e.path=? OR (e.parent=(SELECT id FROM entries WHERE path=?) AND e.name=?)")
        defer { sqlite3_finalize(statement) }
        try bind(path, 1, to: statement)
        try bind(StorageIndex.parent(path), 2, to: statement)
        try bind(path == "." ? "." : String(path.split(separator: "/").last ?? ""), 3, to: statement)
        let status=sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw Self.failure() }
        return try item(statement)
    }
    /// Immediate directories have already been discovered. Page by immutable
    /// names so descendant inserts and aggregate updates cannot shift offsets.
    public func forEachChildDirectory(parentID: Int64, _ consume: (Int64, StorageCatalogItem) throws -> Void) throws {
        guard writable else { throw Self.failure() }
        var after=""
        while true {
            var rows=[(Int64, StorageCatalogItem)]()
            do {
                let statement=try prepare("SELECT " + columns + ",e.id" + Self.source + "WHERE e.parent=? AND e.kind='directory' AND e.name>? ORDER BY e.name LIMIT 256")
                defer { sqlite3_finalize(statement) }
                try bind([parentID], startingAt: 1, to: statement); try bind(after, 2, to: statement)
                while true {
                    let status=sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { throw Self.failure() }
                    rows.append((sqlite3_column_int64(statement, 19), try item(statement)))
                }
            }
            guard !rows.isEmpty else { return }
            for (id, row) in rows { try consume(id, row) }
            after=rows.last!.1.node.name
        }
    }
    public func children(of path: String) throws -> [StorageCatalogItem] {
        let statement=try prepare("SELECT " + columns + Self.source + "WHERE e.parent=(SELECT id FROM entries WHERE path=?) ORDER BY e.total_allocated DESC,e.name")
        defer { sqlite3_finalize(statement) }
        try bind(path, 1, to: statement)
        var result=[StorageCatalogItem]()
        while true {
            if result.count % 4096 == 0, Task.isCancelled { throw ShouError("cancelled", "Directory loading stopped.") }
            let status=sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw Self.failure() }
            result.append(try item(statement))
        }
    }
    func directoryPage(path: String, offset: Int, limit: Int, nameFilter: String = "") throws -> StorageDirectoryPage {
        if Task.isCancelled { throw ShouError("cancelled", "Directory loading stopped.") }
        let checkpoint=CatalogCheckpoint { if Task.isCancelled { throw ShouError("cancelled", "Directory loading stopped.") } }
        sqlite3_progress_handler(database, 4096, { pointer in
            guard let pointer else { return 1 }
            let context=Unmanaged<CatalogCheckpoint>.fromOpaque(pointer).takeUnretainedValue()
            do { try context.check(); return 0 } catch { context.error=error; return 1 }
        }, Unmanaged.passUnretained(checkpoint).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        do { return try readDirectoryPage(path: path, offset: offset, limit: limit, nameFilter: nameFilter) }
        catch { throw checkpoint.error ?? error }
    }
    private func readDirectoryPage(path: String, offset: Int, limit: Int, nameFilter: String) throws -> StorageDirectoryPage {
        guard let root=try entry(at: path), root.node.kind == "directory" else { throw ShouError("invalid_argument", "Directory is absent from this analysis.") }
        try registerNameMatchFunction()
        let predicate="e.parent=(SELECT id FROM entries WHERE path=?1) AND (?2='' OR shou_name_matches(e.name,?2))"
        let count=try prepare("SELECT COUNT(*) FROM entries e WHERE " + predicate)
        defer { sqlite3_finalize(count) }
        try bind(path, 1, to: count); try bind(nameFilter, 2, to: count)
        guard sqlite3_step(count) == SQLITE_ROW else { throw Self.failure() }
        let total=Int(sqlite3_column_int64(count, 0))
        guard offset <= total else { throw ShouError("invalid_argument", "Invalid directory offset.") }
        let statement=try prepare("SELECT " + columns + Self.source + "WHERE " + predicate + " ORDER BY e.total_allocated DESC,e.name LIMIT ?3 OFFSET ?4")
        defer { sqlite3_finalize(statement) }
        try bind(path, 1, to: statement); try bind(nameFilter, 2, to: statement); try bind([Int64(limit), Int64(offset)], startingAt: 3, to: statement)
        var rows=[StorageCatalogItem]()
        while true {
            if Task.isCancelled { throw ShouError("cancelled", "Directory loading stopped.") }
            let status=sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw Self.failure() }
            rows.append(try item(statement))
        }
        let end=offset + rows.count
        return StorageDirectoryPage(item: root, children: rows, totalCount: total, nextOffset: end < total ? end : nil)
    }
    private func registerNameMatchFunction() throws {
        guard sqlite3_create_function_v2(database, "shou_name_matches", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, count, values in
            guard count == 2, let values, let name=sqlite3_value_text(values[0]), let query=sqlite3_value_text(values[1]) else { sqlite3_result_int(context, 0); return }
            sqlite3_result_int(context, String(cString: name).localizedCaseInsensitiveContains(String(cString: query)) ? 1 : 0)
        }, nil, nil, nil) == SQLITE_OK else { throw Self.failure() }
    }
    private func registerExtensionFunction() throws {
        guard sqlite3_create_function_v2(database, "shou_extension", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, count, values in
            guard count == 1, let values, let bytes=sqlite3_value_text(values[0]) else { sqlite3_result_null(context); return }
            let suffix=StorageExtensionStat.suffix(String(cString: bytes))
            suffix.withCString { sqlite3_result_text(context, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }, nil, nil, nil) == SQLITE_OK else { throw Self.failure() }
    }
    func extensionSummary(under path: String) throws -> StorageExtensionSummary {
        try registerExtensionFunction()
        let checkpoint=CatalogCheckpoint { if Task.isCancelled { throw ShouError("cancelled", "Directory loading stopped.") } }
        sqlite3_progress_handler(database, 4096, { pointer in
            guard let pointer else { return 1 }
            let context=Unmanaged<CatalogCheckpoint>.fromOpaque(pointer).takeUnretainedValue()
            do { try context.check(); return 0 } catch { context.error=error; return 1 }
        }, Unmanaged.passUnretained(checkpoint).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        let scope=path == "." ? "" : " AND e.parent IN (SELECT id FROM entries WHERE path=?1 OR (path>=?2 AND path<?3))"
        let statement=try prepare("SELECT shou_extension(e.name),SUM(e.total_allocated),SUM(e.total_logical),COUNT(*) FROM entries e WHERE e.kind='file'" + scope + " GROUP BY shou_extension(e.name) ORDER BY SUM(e.total_allocated) DESC,shou_extension(e.name)")
        defer { sqlite3_finalize(statement) }
        if path != "." { try bind(path, 1, to: statement); try bind(path + "/", 2, to: statement); try bind(path + "0", 3, to: statement) }
        var rows=[StorageExtensionStat](), omitted=StorageExtensionStat(suffix: "", allocatedBytes: 0, logicalBytes: 0, fileCount: 0)
        while true {
            let status=sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let text=sqlite3_column_text(statement, 0) else { throw checkpoint.error ?? Self.failure() }
            let row=StorageExtensionStat(suffix: String(cString: text), allocatedBytes: sqlite3_column_int64(statement, 1), logicalBytes: sqlite3_column_int64(statement, 2), fileCount: Int(sqlite3_column_int64(statement, 3)))
            if rows.count < 100 { rows.append(row) } else { omitted.allocatedBytes += row.allocatedBytes; omitted.logicalBytes += row.logicalBytes; omitted.fileCount += row.fileCount }
        }
        return StorageExtensionSummary(items: rows, omitted: omitted)
    }
    /// Assigns files to their closest displayed ancestor with one index traversal.
    func mapFileExtensionGroups(scope: String, visibleDirectories: [String]) throws -> (groups: [StorageMapAggregate], extensions: StorageExtensionSummary) {
        guard !visibleDirectories.isEmpty, visibleDirectories.count <= 8193 else { throw Self.failure() }
        try registerExtensionFunction()
        let checkpoint=CatalogCheckpoint { if Task.isCancelled { throw ShouError("cancelled", "Directory loading stopped.") } }
        sqlite3_progress_handler(database, 4096, { pointer in
            guard let pointer else { return 1 }
            let context=Unmanaged<CatalogCheckpoint>.fromOpaque(pointer).takeUnretainedValue()
            do { try context.check(); return 0 } catch { context.error=error; return 1 }
        }, Unmanaged.passUnretained(checkpoint).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        let visible=CatalogMapDirectories()
        for offset in stride(from: 0, to: visibleDirectories.count, by: 256) {
            let paths=Array(visibleDirectories[offset..<min(offset+256,visibleDirectories.count)])
            let parameters=Array(repeating: "?",count:paths.count).joined(separator:",")
            let query=try prepare("SELECT id FROM entries WHERE path IN (" + parameters + ")")
            defer { sqlite3_finalize(query) }
            for (index,path) in paths.enumerated() { try bind(path,Int32(index+1),to:query) }
            while true {
                let status=sqlite3_step(query)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw checkpoint.error ?? Self.failure() }
                visible.ids.insert(sqlite3_column_int64(query,0))
            }
        }
        guard sqlite3_create_function_v2(database,"shou_map_visible",1,SQLITE_UTF8 | SQLITE_DETERMINISTIC,Unmanaged.passUnretained(visible).toOpaque(), { context,count,values in
            guard count == 1, let values, let pointer=sqlite3_user_data(context) else { sqlite3_result_int(context,0); return }
            let visible=Unmanaged<CatalogMapDirectories>.fromOpaque(pointer).takeUnretainedValue()
            sqlite3_result_int(context,visible.ids.contains(sqlite3_value_int64(values[0])) ? 1 : 0)
        },nil,nil,nil) == SQLITE_OK else { throw Self.failure() }
        defer {
            withExtendedLifetime(visible) {
                _ = sqlite3_create_function_v2(database,"shou_map_visible",1,SQLITE_UTF8,nil,nil,nil,nil,nil)
            }
        }
        let statement=try prepare("""
            WITH RECURSIVE mapped(id,scope) AS (
                SELECT id,id FROM entries WHERE path=?1
                UNION ALL
                SELECT child.id,CASE WHEN shou_map_visible(child.id)=1 THEN child.id ELSE mapped.scope END
                FROM mapped JOIN entries child ON child.parent=mapped.id
                WHERE child.kind='directory'
            )
            ,grouped AS MATERIALIZED (
                SELECT mapped.scope,shou_extension(e.name) AS suffix,
                    SUM(e.total_allocated) AS allocated,SUM(e.total_logical) AS logical,COUNT(*) AS files
                FROM mapped JOIN entries e ON e.parent=mapped.id WHERE e.kind='file'
                GROUP BY mapped.scope,shou_extension(e.name)
            )
            SELECT 0,g.path,g.suffix,g.allocated,g.logical,g.files FROM (
                SELECT container.path,grouped.* FROM grouped JOIN entries container ON container.id=grouped.scope
                ORDER BY allocated DESC,container.path,suffix LIMIT 10240
            ) g
            UNION ALL
            SELECT 1,'',suffix,SUM(allocated),SUM(logical),SUM(files) FROM grouped GROUP BY suffix
            """)
        defer { sqlite3_finalize(statement) }
        try bind(scope,1,to:statement)
        var rows=[StorageMapAggregate](), types=[StorageExtensionStat]()
        while true {
            if Task.isCancelled { throw ShouError("cancelled", "Directory loading stopped.") }
            let status=sqlite3_step(statement)
            if status == SQLITE_DONE { return (rows,ShouEngine.extensionSummary(types)) }
            guard status == SQLITE_ROW, let path=sqlite3_column_text(statement,1), let suffix=sqlite3_column_text(statement,2) else { throw checkpoint.error ?? Self.failure() }
            let name=String(cString:suffix), allocated=sqlite3_column_int64(statement,3), logical=sqlite3_column_int64(statement,4), count=Int(sqlite3_column_int64(statement,5))
            if sqlite3_column_int(statement,0) == 1 {
                types.append(StorageExtensionStat(suffix:name,allocatedBytes:allocated,logicalBytes:logical,fileCount:count))
            } else {
                rows.append(StorageMapAggregate(parentPath:String(cString:path),suffix:name,allocatedBytes:allocated,logicalBytes:logical,fileCount:count))
            }
        }
    }
    func largeFiles(query: StorageLargeFileQuery) throws -> StorageLargeFilePage {
        try StorageLargeFileQuery.checkpoint()
        // Both SQLite and legacy snapshots use the same extension policy.
        guard sqlite3_create_function_v2(database, "shou_file_type", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, count, values in
            guard count == 1, let values, let bytes=sqlite3_value_text(values[0]) else { sqlite3_result_null(context); return }
            let type=StorageFileType.classify(name: String(cString: bytes)).rawValue
            type.withCString { sqlite3_result_text(context, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }, nil, nil, nil) == SQLITE_OK else { throw Self.failure() }
        let context=CatalogCheckpoint(StorageLargeFileQuery.checkpoint)
        sqlite3_progress_handler(database, 4096, { pointer in
            guard let pointer else { return 1 }
            let context=Unmanaged<CatalogCheckpoint>.fromOpaque(pointer).takeUnretainedValue()
            do { try context.check(); return 0 }
            catch { context.error=error; return 1 }
        }, Unmanaged.passUnretained(context).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        do {
            // SQLite cannot infer a parameter's lower bound for a partial index.
            // Keep the literal predicate when it is implied by this query. Older
            // catalogs remain readable and simply use their existing scan path.
            let indexedFloor=query.minimumBytes >= 1_048_576 ? " AND e.total_allocated>=1048576" : ""
            let condition="WHERE e.kind='file'" + indexedFloor + " AND e.total_allocated>=?1 AND (?2='all' OR shou_file_type(e.name)=?2)"
            let totals=try prepare("SELECT COUNT(*),COALESCE(SUM(e.total_allocated),0) FROM entries e " + condition)
            defer { sqlite3_finalize(totals) }
            try bind([query.minimumBytes], startingAt: 1, to: totals)
            try bind(query.type.rawValue, 2, to: totals)
            guard sqlite3_step(totals) == SQLITE_ROW else { throw Self.failure() }
            let count=sqlite3_column_int64(totals, 0), allocated=sqlite3_column_int64(totals, 1)
            guard count >= 0, count <= Int64(Int.max), allocated >= 0 else { throw Self.failure() }
            let after=" AND (?3 IS NULL OR e.total_allocated<?3 OR (e.total_allocated=?3 AND " + Self.pathColumn + " COLLATE BINARY>?4 COLLATE BINARY))"
            let statement=try prepare("SELECT " + columns + Self.source + condition + after +
                " ORDER BY e.total_allocated DESC," + Self.pathColumn + " COLLATE BINARY ASC LIMIT ?5")
            defer { sqlite3_finalize(statement) }
            try bind([query.minimumBytes], startingAt: 1, to: statement)
            try bind(query.type.rawValue, 2, to: statement)
            if let cursor=query.after {
                try bind([cursor.allocatedBytes], startingAt: 3, to: statement)
                try bind(cursor.path, 4, to: statement)
            } else {
                guard sqlite3_bind_null(statement, 3) == SQLITE_OK, sqlite3_bind_null(statement, 4) == SQLITE_OK else { throw Self.failure() }
            }
            try bind([Int64(query.limit + 1)], startingAt: 5, to: statement)
            var items=[StorageCatalogItem]()
            while true {
                try StorageLargeFileQuery.checkpoint()
                let status=sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw Self.failure() }
                items.append(try item(statement))
            }
            return try query.page(items, totalCount: Int(count), totalAllocatedBytes: allocated)
        } catch { throw context.error ?? error }
    }
    public func forEachEntry(under path: String = ".", _ body: (FileEntry) throws -> Void) throws {
        if path != ".", let item=try entry(at: path), item.entry.kind != "directory" { try body(item.entry); return }
        let condition=path == "." ? "" : "WHERE e.path=? OR e.parent IN (SELECT id FROM entries WHERE path=? OR (path>=? AND path<?))"
        let statement=try prepare("SELECT " + columns + Self.source + condition)
        defer { sqlite3_finalize(statement) }
        if path != "." {
            try bind(path, 1, to: statement); try bind(path, 2, to: statement)
            try bind(path + "/", 3, to: statement); try bind(path + "0", 4, to: statement)
        }
        while true {
            if Task.isCancelled { throw ShouError("cancelled", "Directory loading stopped.") }
            let status=sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw Self.failure() }
            try body(try item(statement).entry)
        }
    }
}
