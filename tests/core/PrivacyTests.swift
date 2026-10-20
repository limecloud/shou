import Foundation
import CSQLite
import ShouCore
import ShouPlatform

private let privacyDate=Date(timeIntervalSince1970: 2_000_000_000)
private let chromeHistory="Library/Application Support/Google/Chrome/Default/History"
private let chromeCookies="Library/Application Support/Google/Chrome/Default/Network/Cookies"

private final class PrivacyActivityFixture: ApplicationActivityChecking, @unchecked Sendable {
    private let lock=NSLock()
    private var active=false
    func setRunning(_ value: Bool) { lock.lock(); defer { lock.unlock() }; active=value }
    func runningBundleIdentifiers(in identifiers: Set<String>) throws -> Set<String> { lock.lock(); defer { lock.unlock() }; return active ? identifiers : [] }
}
private func privacySQL(_ url: URL, _ sql: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CheckFailure(description: "Generated privacy fixture could not be opened.") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CheckFailure(description: "Generated privacy fixture SQL failed.") }
}
private func privacyScalar(_ url: URL, _ sql: String) throws -> Int64 {
    var db: OpaquePointer?, query: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CheckFailure(description: "Generated privacy fixture could not be read.") }
    defer { sqlite3_finalize(query); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, sqlite3_step(query) == SQLITE_ROW else { throw CheckFailure(description: "Generated privacy aggregate query failed.") }
    return sqlite3_column_int64(query, 0)
}
private func privacyService(_ fixture: Fixture, activity: PrivacyActivityFixture = PrivacyActivityFixture()) -> PrivacyService {
    PrivacyService(store: fixture.store, filesystem: fixture.fs, activity: activity, sources: NativePrivacySources(), home: fixture.workspace, now: { privacyDate })
}
private func chromeSchema(recent: Int64, old: Int64, constraint: String = "") -> String {
    """
    CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,visit_count INTEGER \(constraint),typed_count INTEGER,last_visit_time INTEGER);
    CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER,transition INTEGER,from_visit INTEGER,opener_visit INTEGER,visited_link_id INTEGER);
    INSERT INTO urls VALUES(1,'https://private.example/secret',2,1,\(recent));
    INSERT INTO visits VALUES(1,1,\(old),1,0,0,10),(2,1,\(recent),0,1,1,20);
    CREATE TABLE visited_links(id INTEGER); INSERT INTO visited_links VALUES(10),(20),(99);
    CREATE TABLE clusters(cluster_id INTEGER); INSERT INTO clusters VALUES(10),(20),(99);
    CREATE TABLE clusters_and_visits(cluster_id INTEGER,visit_id INTEGER); INSERT INTO clusters_and_visits VALUES(10,1),(20,2);
    CREATE TABLE visit_source(id INTEGER); INSERT INTO visit_source VALUES(1),(2);
    CREATE TABLE downloads(id INTEGER); INSERT INTO downloads VALUES(7);
    """
}

func privacyChromiumRangePreservesUnselectedRelationsAndReceipts() async throws {
    let fixture=try Fixture(), service=privacyService(fixture)
    let recent=Int64((privacyDate.timeIntervalSince1970 + 11_644_473_600 - 60) * 1_000_000)
    let old=recent - 7_200_000_000, url=fixture.workspace.appendingPathComponent(chromeHistory)
    try privacySQL(url, chromeSchema(recent: recent, old: old))
    let scan=try await service.scan(range: .lastHour)
    let source=try require(scan.sources.first { $0.definition.relativePath == chromeHistory })
    try expect(source.status == .ready && source.recordCount == 1)
    let plan=try await service.preparePlan(scanId: scan.id, sourceIDs: [source.id])
    try await expectThrows { try await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: false)) }
    let result=try await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: true))
    try expect(result.state == "completed" && result.items.first?.removedRecords == 1)
    try expect(try privacyScalar(url, "SELECT COUNT(*) FROM visits") == 1)
    try expect(try privacyScalar(url, "SELECT visit_count FROM urls WHERE id=1") == 1)
    try expect(try privacyScalar(url, "SELECT typed_count FROM urls WHERE id=1") == 1)
    try expect(try privacyScalar(url, "SELECT COUNT(*) FROM visited_links WHERE id=99") == 1)
    try expect(try privacyScalar(url, "SELECT COUNT(*) FROM visited_links WHERE id=20") == 0)
    try expect(try privacyScalar(url, "SELECT COUNT(*) FROM clusters WHERE cluster_id=99") == 1)
    try expect(try privacyScalar(url, "SELECT COUNT(*) FROM clusters WHERE cluster_id=20") == 0)
    try expect(try privacyScalar(url, "SELECT COUNT(*) FROM downloads") == 1)
    let receipt=String(decoding: try Codec.encode(result), as: UTF8.self)
    try expect(!receipt.contains("private.example") && !receipt.contains("Library/") && !receipt.contains("Default"))
    try expect(try await service.history().count == 1)
    try await expectThrows { try await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: true)) }
}

func privacyCookiesRequireSeparateConsentAndUseLastAccessTime() async throws {
    let fixture=try Fixture(), service=privacyService(fixture), url=fixture.workspace.appendingPathComponent(chromeCookies)
    let recent=Int64((privacyDate.timeIntervalSince1970 + 11_644_473_600 - 60) * 1_000_000)
    try privacySQL(url, "CREATE TABLE cookies(host_key TEXT,value TEXT,last_access_utc INTEGER); INSERT INTO cookies VALUES('private.example','private-cookie',\(recent)),('old.example','old-cookie',\(recent-7_200_000_000));")
    let scan=try await service.scan(range: .lastHour), source=try require(scan.sources.first { $0.definition.relativePath == chromeCookies })
    try expect(source.requiresSignOutConsent && source.recordCount == 1)
    try await expectThrows { try await service.preparePlan(scanId: scan.id, sourceIDs: [source.id]) }
    let plan=try await service.preparePlan(scanId: scan.id, sourceIDs: [source.id], acknowledgeSignOut: true)
    try await expectThrows { try await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: true)) }
    let result=try await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: true, signOut: true))
    try expect(result.state == "completed" && result.items[0].removedRecords == 1)
    try expect(try privacyScalar(url, "SELECT COUNT(*) FROM cookies") == 1)
    let text=String(decoding: try Codec.encode(result), as: UTF8.self)
    try expect(!text.contains("private-cookie") && !text.contains("private.example"))
}

func privacyFirefoxAndSafariEpochsPreserveBookmarksAndDownloads() async throws {
    let fixture=try Fixture(), service=privacyService(fixture)
    let firefox=fixture.workspace.appendingPathComponent("Library/Application Support/Firefox/Profiles/generated.default/places.sqlite")
    let safari=fixture.workspace.appendingPathComponent("Library/Safari/History.db")
    let ff=Int64((privacyDate.timeIntervalSince1970-60)*1_000_000), sf=Int64(privacyDate.timeIntervalSince1970-978_307_200-60)
    try privacySQL(firefox, "CREATE TABLE moz_places(id INTEGER PRIMARY KEY,foreign_count INTEGER,visit_count INTEGER,last_visit_date INTEGER); CREATE TABLE moz_historyvisits(place_id INTEGER,visit_type INTEGER,visit_date INTEGER); CREATE TABLE moz_bookmarks(fk INTEGER); INSERT INTO moz_places VALUES(1,1,1,\(ff)),(2,0,1,\(ff)),(3,0,0,\(ff)); INSERT INTO moz_bookmarks VALUES(1); INSERT INTO moz_historyvisits VALUES(1,1,\(ff)),(2,1,\(ff-7_200_000_000)),(3,7,\(ff));")
    try privacySQL(safari, "CREATE TABLE history_items(id INTEGER PRIMARY KEY,visit_count INTEGER); CREATE TABLE history_visits(history_item INTEGER,visit_time REAL); INSERT INTO history_items VALUES(1,2); INSERT INTO history_visits VALUES(1,\(sf)),(1,\(sf-7200));")
    let scan=try await service.scan(range: .lastHour)
    let sources=scan.sources.filter { $0.eligible && $0.definition.kind == .history }
    try expect(sources.count == 2 && sources.allSatisfy { $0.recordCount == 1 })
    try expect(scan.sources.contains { $0.definition.browser == .safari && $0.definition.kind == .cookies && $0.status == .unsupported })
    let plan=try await service.preparePlan(scanId: scan.id, sourceIDs: sources.map(\.id))
    try expect(try await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: true)).state == "completed")
    try expect(try privacyScalar(firefox, "SELECT COUNT(*) FROM moz_places WHERE id=1") == 1)
    try expect(try privacyScalar(firefox, "SELECT COUNT(*) FROM moz_historyvisits WHERE visit_type=7") == 1)
    try expect(try privacyScalar(safari, "SELECT visit_count FROM history_items WHERE id=1") == 1)
}

func privacyRefusesRunningStaleExcludedAndUnsupportedSources() async throws {
    let fixture=try Fixture(), activity=PrivacyActivityFixture(), service=privacyService(fixture, activity: activity)
    let url=fixture.workspace.appendingPathComponent(chromeCookies)
    try privacySQL(url, "CREATE TABLE cookies(last_access_utc INTEGER); INSERT INTO cookies VALUES(0);")
    activity.setRunning(true)
    let blocked=try await service.scan(range: .allTime)
    try expect(blocked.sources.first { $0.definition.relativePath == chromeCookies }?.status == .browserRunning)
    activity.setRunning(false)
    let scan=try await service.scan(range: .allTime), source=try require(scan.sources.first { $0.definition.relativePath == chromeCookies })
    let plan=try await service.preparePlan(scanId: scan.id, sourceIDs: [source.id], acknowledgeSignOut: true)
    activity.setRunning(true)
    try await expectThrows { try await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: true, signOut: true)) }
    activity.setRunning(false)
    try privacySQL(url, "INSERT INTO cookies VALUES(1)")
    try await expectThrows { try await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: true, signOut: true)) }
    var config=Configuration(); config.globalExclusions=["Library/Application Support/Google/**"]
    try fixture.store.write("configuration", id: "current", data: Codec.encode(config))
    let protected=try await service.scan(range: .allTime)
    try expect(protected.sources.first { $0.definition.relativePath == chromeCookies }?.status == .permissionRequired)
    try expect(try privacyScalar(url, "SELECT COUNT(*) FROM cookies") == 2)
    let definition=PrivacySourceDefinition(browser: .chromium, browserName: "fixture", bundleIdentifier: "com.google.Chrome", profile: "Default", kind: .cookies, relativePath: "Documents/private.sqlite")
    try expect(!PrivacySourcePolicy.valid(definition))
}

func privacyTransactionsRollbackAndUnknownSchemasStayUnavailable() async throws {
    let fixture=try Fixture(), service=privacyService(fixture), url=fixture.workspace.appendingPathComponent(chromeHistory)
    let recent=Int64((privacyDate.timeIntervalSince1970 + 11_644_473_600 - 60) * 1_000_000)
    try privacySQL(url, chromeSchema(recent: recent, old: recent-7_200_000_000, constraint: "CHECK(visit_count>1)"))
    let scan=try await service.scan(range: .lastHour), source=try require(scan.sources.first { $0.definition.relativePath == chromeHistory })
    let plan=try await service.preparePlan(scanId: scan.id, sourceIDs: [source.id])
    let receipt=try await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: true))
    try expect(receipt.state == "partial" && receipt.items[0].removedRecords == 0)
    try expect(try privacyScalar(url, "SELECT COUNT(*) FROM visits") == 2)
    try expect(try privacyScalar(url, "SELECT COUNT(*) FROM visited_links WHERE id=20") == 1)
    try privacySQL(url, "CREATE TRIGGER unknown_browser_trigger BEFORE DELETE ON visits BEGIN SELECT RAISE(ABORT,'private trigger text'); END;")
    let unsupported=try await service.scan(range: .lastHour)
    try expect(unsupported.sources.first { $0.definition.relativePath == chromeHistory }?.status == .schemaUnsupported)
    let text=String(decoding: try Codec.encode(unsupported), as: UTF8.self)
    try expect(!text.contains("private trigger text") && !text.contains("private.example"))
}

func privacyIntegerTimeBoundsAndUnknownCascadesAreConservative() async throws {
    let fixture=try Fixture()
    let service=PrivacyService(store: fixture.store, filesystem: fixture.fs, activity: PrivacyActivityFixture(), sources: NativePrivacySources(), home: fixture.workspace, now: { Date(timeIntervalSince1970: 2_000_000_000.0000012) })
    let chromium=fixture.workspace.appendingPathComponent(chromeCookies)
    let firefox=fixture.workspace.appendingPathComponent("Library/Application Support/Firefox/Profiles/generated.default/cookies.sqlite")
    let unixEnd: Int64=2_000_000_000_000_000, unixStart=unixEnd-3_600_000_000
    for (url, table, column, offset) in [(chromium, "cookies", "last_access_utc", Int64(11_644_473_600_000_000)), (firefox, "moz_cookies", "lastAccessed", Int64(0))] {
        // The representable scan instant is between the first and second microsecond.
        try privacySQL(url, "PRAGMA journal_mode=WAL; CREATE TABLE \(table)(id INTEGER PRIMARY KEY,\(column) INTEGER); INSERT INTO \(table) VALUES(1,\(offset+unixStart+1)),(2,\(offset+unixStart+2)),(3,\(offset+unixEnd+1)),(4,\(offset+unixEnd+2));")
    }
    let scan=try await service.scan(range: .lastHour)
    let sources=scan.sources.filter { $0.eligible && $0.definition.kind == .cookies }
    try expect(sources.count == 2 && sources.allSatisfy { $0.recordCount == 2 })
    let plan=try await service.preparePlan(scanId: scan.id, sourceIDs: sources.map(\.id), acknowledgeSignOut: true)
    let receipt=try await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: true, signOut: true))
    try expect(receipt.state == "completed")
    for (url, table) in [(chromium, "cookies"), (firefox, "moz_cookies")] {
        try expect(try privacyScalar(url, "SELECT COUNT(*) FROM \(table) WHERE id IN (1,4)") == 2)
        try expect(try privacyScalar(url, "SELECT COUNT(*) FROM \(table) WHERE id IN (2,3)") == 0)
    }
    try privacySQL(chromium, "CREATE TABLE unrelated_accounts(id INTEGER PRIMARY KEY,cookie_id INTEGER REFERENCES cookies(id) ON DELETE CASCADE); INSERT INTO unrelated_accounts VALUES(1,1);")
    let unsupported=try await service.scan(range: .allTime)
    try expect(unsupported.sources.first { $0.definition.relativePath == chromeCookies }?.status == .schemaUnsupported)
    try expect(try privacyScalar(chromium, "SELECT COUNT(*) FROM unrelated_accounts") == 1)
}
