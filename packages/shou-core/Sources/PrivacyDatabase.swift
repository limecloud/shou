import Foundation
import CSQLite

private final class PrivacyQueryBudget {
    let deadline=Date().addingTimeInterval(15)
    var stopped=false
}

/// Only aggregate counts leave this connection. SQL and schema names are static.
final class PrivacyDatabase {
    private var connection: OpaquePointer?
    private let source: PrivacySourceDefinition
    private let start: Date?
    private let end: Date
    private let budget=PrivacyQueryBudget()
    private let transient=unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(path: String, source: PrivacySourceDefinition, start: Date?, end: Date, writable: Bool) throws {
        self.source=source; self.start=start; self.end=end
        let flags=(writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &connection, flags, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }; connection=nil
            throw ShouError("privacy_database_unavailable", "The privacy database could not be opened safely.")
        }
        do {
            sqlite3_busy_timeout(connection, 1000)
            sqlite3_progress_handler(connection, 1000, { context in
                guard let context else { return 1 }
                let budget=Unmanaged<PrivacyQueryBudget>.fromOpaque(context).takeUnretainedValue()
                if Task.isCancelled || Date() >= budget.deadline { budget.stopped=true; return 1 }
                return 0
            }, Unmanaged.passUnretained(budget).toOpaque())
            try execute("PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON; PRAGMA mmap_size=0; PRAGMA cache_size=-2048;")
            if !writable { try execute("PRAGMA query_only=ON") }
            try validateSchema()
        } catch { sqlite3_close(connection); connection=nil; throw error }
    }
    deinit { close() }
    func close() {
        if let connection { sqlite3_progress_handler(connection, 0, nil, nil); sqlite3_close(connection) }
        connection=nil
    }
    private func failure() -> ShouError {
        if Task.isCancelled { return ShouError("cancelled", "Privacy operation cancelled.") }
        if budget.stopped { return ShouError("privacy_query_limit", "The privacy database operation exceeded its time limit.") }
        let code=sqlite3_errcode(connection)
        return ShouError(code == SQLITE_BUSY || code == SQLITE_LOCKED ? "privacy_database_busy" : "privacy_database_unavailable", "The privacy database operation failed; no record contents were logged.")
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &value, nil) == SQLITE_OK, let value else { throw failure() }
        return value
    }
    private func exists(_ table: String) throws -> Bool {
        let query=try statement("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?")
        defer { sqlite3_finalize(query) }
        guard sqlite3_bind_text(query, 1, table, -1, transient) == SQLITE_OK else { throw failure() }
        let result=sqlite3_step(query)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure() }
        return result == SQLITE_ROW
    }
    private func columns(_ table: String) throws -> Set<String> {
        // Every caller supplies a compile-time table name, never external input.
        let query=try statement("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(query) }
        var names=Set<String>()
        while true {
            let result=sqlite3_step(query)
            if result == SQLITE_DONE { return names }
            guard result == SQLITE_ROW, let name=sqlite3_column_text(query, 1) else { throw failure() }
            names.insert(String(cString: name))
        }
    }
    private func require(_ table: String, _ required: Set<String>) throws {
        guard try exists(table), required.isSubset(of: try columns(table)) else { throw ShouError("privacy_schema_unsupported", "The browser database schema is unsupported; it was preserved.") }
    }
    private func optional(_ table: String, _ required: Set<String>, _ sql: String? = nil) throws {
        if try exists(table) { try require(table, required); if let sql { try execute(sql) } }
    }
    private func validateSchema() throws {
        let triggers=try statement("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger'")
        defer { sqlite3_finalize(triggers) }
        guard sqlite3_step(triggers) == SQLITE_ROW, sqlite3_column_int64(triggers, 0) == 0 else { throw ShouError("privacy_schema_unsupported", "Browser-specific database triggers are unsupported; the source was preserved.") }
        switch (source.browser, source.kind) {
        case (.chromium, .history):
            try require("visits", ["id", "url", "visit_time"]); try require("urls", ["id"])
            for (table, names) in [("visit_source", Set(["id"])), ("content_annotations", ["visit_id"]), ("context_annotations", ["visit_id"]), ("clusters_and_visits", ["cluster_id", "visit_id"]), ("cluster_visit_duplicates", ["visit_id", "duplicate_visit_id"]), ("keyword_search_terms", ["url_id"]), ("segments", ["id", "url_id"]), ("segment_usage", ["segment_id"]), ("clusters", ["cluster_id"])] {
                try optional(table, names)
            }
            if try exists("visited_links") { try require("visited_links", ["id"]); try require("visits", ["visited_link_id"]) }
            if try columns("urls").contains("typed_count") { try require("visits", ["transition"]) }
            if try exists("segment_usage"), try !exists("segments") { throw ShouError("privacy_schema_unsupported", "The browser database schema is unsupported; it was preserved.") }
        case (.firefox, .history):
            try require("moz_historyvisits", ["place_id", "visit_type", "visit_date"])
            try require("moz_places", ["id", "foreign_count"]); try require("moz_bookmarks", ["fk"])
            guard try columns("moz_places").isDisjoint(with: ["frecency", "alt_frecency", "recalc_frecency", "recalc_alt_frecency"]) else { throw ShouError("privacy_schema_unsupported", "Browser-specific history scoring is unsupported; the source was preserved.") }
        case (.safari, .history):
            try require("history_visits", ["history_item", "visit_time"]); try require("history_items", ["id"])
            guard try columns("history_items").isDisjoint(with: ["daily_visit_counts", "weekly_visit_counts", "autocompletion_triggers"]) else { throw ShouError("privacy_schema_unsupported", "Browser-specific history aggregates are unsupported; the source was preserved.") }
        case (.chromium, .cookies): try require("cookies", ["last_access_utc"])
        case (.firefox, .cookies): try require("moz_cookies", ["lastAccessed"])
        default: throw ShouError("privacy_schema_unsupported", "This privacy source is not supported.")
        }
        try validateForeignKeys()
    }
    private func validateForeignKeys() throws {
        let known: Set<String>
        switch (source.browser, source.kind) {
        case (.chromium, .history): known=["visits", "urls", "visit_source", "content_annotations", "context_annotations", "clusters_and_visits", "cluster_visit_duplicates", "keyword_search_terms", "segments", "segment_usage", "clusters", "visited_links"]
        case (.firefox, .history): known=["moz_historyvisits", "moz_places", "moz_bookmarks"]
        case (.safari, .history): known=["history_visits", "history_items"]
        case (.chromium, .cookies): known=["cookies"]
        default: known=["moz_cookies"]
        }
        let tables=try statement("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        defer { sqlite3_finalize(tables) }
        var names=[String]()
        while true {
            let result=sqlite3_step(tables)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let name=sqlite3_column_text(tables, 0), names.count < 256 else { throw ShouError("privacy_schema_unsupported", "The browser database schema is unsupported; it was preserved.") }
            names.append(String(cString: name))
        }
        for table in names {
            // Bind schema identifiers as values; database-supplied names never become SQL.
            let query=try statement("SELECT \"table\" FROM pragma_foreign_key_list(?1)")
            defer { sqlite3_finalize(query) }
            guard sqlite3_bind_text(query, 1, table, -1, transient) == SQLITE_OK else { throw failure() }
            while true {
                let result=sqlite3_step(query)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW, let target=sqlite3_column_text(query, 0) else { throw failure() }
                let referenced=String(cString: target).lowercased()
                guard known.contains(table.lowercased()) == known.contains(referenced) else { throw ShouError("privacy_schema_unsupported", "Unknown browser database relationships are unsupported; the source was preserved.") }
            }
        }
    }
    private var tableAndTime: (String, String) {
        switch (source.browser, source.kind) {
        case (.chromium, .history): ("visits", "visit_time")
        case (.chromium, .cookies): ("cookies", "last_access_utc")
        case (.firefox, .history): ("moz_historyvisits", "visit_date")
        case (.firefox, .cookies): ("moz_cookies", "lastAccessed")
        default: ("history_visits", "visit_time")
        }
    }
    private func integerTimestamp(_ date: Date, lowerBound: Bool) throws -> Int64 {
        let value=(date.timeIntervalSince1970 * 1_000_000).rounded(lowerBound ? .up : .down)
        guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else { throw ShouError("invalid_argument", "The privacy time range is outside supported bounds.") }
        let offset: Int64=source.browser == .chromium ? 11_644_473_600_000_000 : 0
        let result=Int64(value).addingReportingOverflow(offset)
        guard !result.overflow else { throw ShouError("invalid_argument", "The privacy time range is outside supported bounds.") }
        return result.partialValue
    }
    private var predicate: String {
        var terms=[String]()
        if source.browser == .firefox && source.kind == .history { terms.append("visit_type <> 7") }
        if start != nil { terms.append("\(tableAndTime.1) >= ?1 AND \(tableAndTime.1) <= ?2") }
        return terms.isEmpty ? "1" : terms.joined(separator: " AND ")
    }
    private func filtered(_ sql: String) throws -> OpaquePointer {
        let query=try statement(sql)
        do {
            if let start {
                let first: Int32, last: Int32
                if source.browser == .safari {
                    first=sqlite3_bind_double(query, 1, start.timeIntervalSince1970 - 978_307_200)
                    last=sqlite3_bind_double(query, 2, end.timeIntervalSince1970 - 978_307_200)
                } else {
                    first=sqlite3_bind_int64(query, 1, try integerTimestamp(start, lowerBound: true))
                    last=sqlite3_bind_int64(query, 2, try integerTimestamp(end, lowerBound: false))
                }
                guard first == SQLITE_OK, last == SQLITE_OK else { throw failure() }
            }
            return query
        } catch { sqlite3_finalize(query); throw error }
    }
    func count() throws -> Int64 {
        let query=try filtered("SELECT COUNT(*) FROM \(tableAndTime.0) WHERE \(predicate)")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(query, 0)
    }
    private func mutate(_ sql: String) throws {
        let query=try filtered(sql); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
    }
    /// The owner and file identities are rechecked inside the write transaction.
    func remove(expectedCount: Int64, beforeMutation: () throws -> Void) throws -> Int64 {
        try execute("BEGIN IMMEDIATE")
        var committed=false
        defer { if !committed { try? execute("ROLLBACK") } }
        try validateSchema()
        guard try count() == expectedCount else { throw ShouError("plan_stale", "Privacy record counts changed; scan again.") }
        try beforeMutation()
        switch (source.browser, source.kind) {
        case (.chromium, .history): try removeChromiumHistory()
        case (.firefox, .history):
            try mutate("CREATE TEMP TABLE shou_privacy_places AS SELECT DISTINCT place_id FROM moz_historyvisits WHERE \(predicate)")
            try mutate("DELETE FROM moz_historyvisits WHERE \(predicate)")
            try execute("DELETE FROM moz_places WHERE id IN (SELECT place_id FROM shou_privacy_places) AND foreign_count=0 AND NOT EXISTS (SELECT 1 FROM moz_historyvisits WHERE place_id=moz_places.id) AND NOT EXISTS (SELECT 1 FROM moz_bookmarks WHERE fk=moz_places.id)")
            let fields=try columns("moz_places")
            for (column, value) in [("visit_count", "COUNT(*)"), ("last_visit_date", "MAX(visit_date)")] where fields.contains(column) {
                try execute("UPDATE moz_places SET \(column)=(SELECT \(value) FROM moz_historyvisits WHERE place_id=moz_places.id AND visit_type<>7) WHERE id IN (SELECT place_id FROM shou_privacy_places)")
            }
        case (.safari, .history):
            try mutate("CREATE TEMP TABLE shou_privacy_items AS SELECT DISTINCT history_item FROM history_visits WHERE \(predicate)")
            try mutate("DELETE FROM history_visits WHERE \(predicate)")
            try execute("DELETE FROM history_items WHERE id IN (SELECT history_item FROM shou_privacy_items) AND NOT EXISTS (SELECT 1 FROM history_visits WHERE history_item=history_items.id)")
            if try columns("history_items").contains("visit_count") {
                try execute("UPDATE history_items SET visit_count=(SELECT COUNT(*) FROM history_visits WHERE history_item=history_items.id) WHERE id IN (SELECT history_item FROM shou_privacy_items)")
            }
        default: try mutate("DELETE FROM \(tableAndTime.0) WHERE \(predicate)")
        }
        guard try count() == 0 else { throw ShouError("privacy_verification_failed", "The selected privacy records remain; the transaction was rolled back.") }
        if Task.isCancelled { throw ShouError("cancelled", "Privacy operation cancelled.") }
        try execute("COMMIT"); committed=true
        return expectedCount
    }
    private func removeChromiumHistory() throws {
        try mutate("CREATE TEMP TABLE shou_privacy_visits AS SELECT id,url FROM visits WHERE \(predicate)")
        if try exists("visited_links") { try execute("CREATE TEMP TABLE shou_privacy_links AS SELECT DISTINCT visited_link_id AS id FROM visits WHERE id IN (SELECT id FROM shou_privacy_visits)") }
        if try exists("clusters_and_visits") { try execute("CREATE TEMP TABLE shou_privacy_clusters AS SELECT DISTINCT cluster_id FROM clusters_and_visits WHERE visit_id IN (SELECT id FROM shou_privacy_visits)") }
        try optional("visit_source", ["id"], "DELETE FROM visit_source WHERE id IN (SELECT id FROM shou_privacy_visits)")
        for table in ["content_annotations", "context_annotations", "clusters_and_visits"] {
            try optional(table, ["visit_id"], "DELETE FROM \(table) WHERE visit_id IN (SELECT id FROM shou_privacy_visits)")
        }
        try optional("cluster_visit_duplicates", ["visit_id", "duplicate_visit_id"], "DELETE FROM cluster_visit_duplicates WHERE visit_id IN (SELECT id FROM shou_privacy_visits) OR duplicate_visit_id IN (SELECT id FROM shou_privacy_visits)")
        let visitColumns=try columns("visits")
        for column in ["from_visit", "opener_visit"] where visitColumns.contains(column) {
            try execute("UPDATE visits SET \(column)=0 WHERE \(column) IN (SELECT id FROM shou_privacy_visits)")
        }
        try execute("DELETE FROM visits WHERE id IN (SELECT id FROM shou_privacy_visits)")
        try optional("visited_links", ["id"], "DELETE FROM visited_links WHERE id IN (SELECT id FROM shou_privacy_links) AND NOT EXISTS (SELECT 1 FROM visits WHERE visited_link_id=visited_links.id)")
        if try exists("segments") {
            try optional("segment_usage", ["segment_id"], "DELETE FROM segment_usage WHERE segment_id IN (SELECT id FROM segments WHERE url_id IN (SELECT url FROM shou_privacy_visits) AND NOT EXISTS (SELECT 1 FROM visits WHERE url=segments.url_id))")
            try execute("DELETE FROM segments WHERE url_id IN (SELECT url FROM shou_privacy_visits) AND NOT EXISTS (SELECT 1 FROM visits WHERE url=segments.url_id)")
        }
        try optional("keyword_search_terms", ["url_id"], "DELETE FROM keyword_search_terms WHERE url_id IN (SELECT url FROM shou_privacy_visits) AND NOT EXISTS (SELECT 1 FROM visits WHERE url=keyword_search_terms.url_id)")
        try execute("DELETE FROM urls WHERE id IN (SELECT url FROM shou_privacy_visits) AND NOT EXISTS (SELECT 1 FROM visits WHERE url=urls.id)")
        let urlColumns=try columns("urls")
        for (column, value) in [("visit_count", "COUNT(*)"), ("last_visit_time", "MAX(visit_time)"), ("typed_count", "SUM(CASE WHEN (transition & 255)=1 THEN 1 ELSE 0 END)")] where urlColumns.contains(column) {
            try execute("UPDATE urls SET \(column)=(SELECT \(value) FROM visits WHERE url=urls.id) WHERE id IN (SELECT url FROM shou_privacy_visits)")
        }
        if try exists("clusters"), try exists("clusters_and_visits") {
            try execute("DELETE FROM clusters WHERE cluster_id IN (SELECT cluster_id FROM shou_privacy_clusters) AND NOT EXISTS (SELECT 1 FROM clusters_and_visits WHERE cluster_id=clusters.cluster_id)")
        }
    }
}
