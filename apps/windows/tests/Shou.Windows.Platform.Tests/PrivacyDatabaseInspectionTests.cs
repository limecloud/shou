using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

/// <summary>Generated SQLite fixtures validate SQL only. macOS uses its own SQLite, without Win32/ACL claims.</summary>
public sealed class PrivacyDatabaseInspectionTests
{
    static PrivacyDatabaseInspectionTests()
    {
        if (OperatingSystem.IsMacOS())
            NativeLibrary.SetDllImportResolver(typeof(WindowsPrivacyDatabaseInspection).Assembly, (name, _, _) =>
                name == "winsqlite3.dll" ? NativeLibrary.Load("/usr/lib/libsqlite3.dylib") : 0);
    }
    private static readonly WindowsPrivacySourcePolicy Policy = new(new(WindowsPath.Parse("C:/Users/Test"),
        WindowsPath.Parse("C:/Users/Test/AppData/Local"), WindowsPath.Parse("C:/Users/Test/AppData/Roaming")));
    private static readonly DateTimeOffset Now = new(2026, 10, 23, 1, 0, 0, TimeSpan.Zero);
    private static readonly PrivacyWindow Window = PrivacyWindow.Create(PrivacyTimeRange.LastHour, Now);
    private const string HistorySchema = "CREATE TABLE urls(id INTEGER PRIMARY KEY); CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER);";

    private sealed class Database : IDisposable
    {
        private readonly string directory = System.IO.Path.Combine(TemporaryRoot(), "shou-privacy-sqlite-" + Guid.NewGuid().ToString("N"));
        public string Path { get; }
        public Database(string sql)
        {
            Directory.CreateDirectory(directory); Path = System.IO.Path.Combine(directory, "generated.sqlite");
            File.WriteAllBytes(Path, []);
            using var database = new PrivacySqlite(Path, readOnly: false, CancellationToken.None); database.Execute(sql);
        }
        public (long Count, string SchemaDigest) Inspect(PrivacySourceDefinition source, PrivacyWindow? window = null, CancellationToken token = default) =>
            PrivacyDatabaseInspection.Inspect(Path, source, window ?? Window, token);
        public byte[] Hash() => SHA256.HashData(File.ReadAllBytes(Path));
        public void Dispose() => Directory.Delete(directory, recursive: true);
    }
    private static string TemporaryRoot()
    {
        var root = Path.GetTempPath();
        // SQLite NOFOLLOW rejects macOS /var's system symlink as well as a linked database.
        return OperatingSystem.IsMacOS() && root.StartsWith("/var/", StringComparison.Ordinal)
            ? new DirectoryInfo("/var").ResolveLinkTarget(returnFinalTarget: true)!.FullName + root[4..] : root;
    }
    private static PrivacySourceDefinition Source(PrivacyBrowser browser = PrivacyBrowser.Chrome, bool cookies = false) =>
        Policy.Create(browser, browser == PrivacyBrowser.Firefox ? "generated.default" : "Default", browser == PrivacyBrowser.Firefox
            ? cookies ? PrivacyDatabaseLocation.FirefoxCookies : PrivacyDatabaseLocation.FirefoxHistory
            : cookies ? PrivacyDatabaseLocation.NetworkCookies : PrivacyDatabaseLocation.History);

    [Theory]
    [InlineData(PrivacyBrowser.Chrome)]
    [InlineData(PrivacyBrowser.Chromium)]
    [InlineData(PrivacyBrowser.Edge)]
    [InlineData(PrivacyBrowser.Brave)]
    public void ChromiumHistoryCountsOnlyTheFixedInclusiveIntegerWindow(PrivacyBrowser browser)
    {
        var (start, end) = Window.IntegerMicroseconds(true);
        using var db = new Database(HistorySchema + $"INSERT INTO urls VALUES(1); INSERT INTO visits VALUES(1,1,{start - 1}),(2,1,{start}),(3,1,{end}),(4,1,{end + 1});");
        var before = db.Hash(); var result = db.Inspect(Source(browser)); Assert.Equal(2, result.Count);
        Assert.StartsWith("sha256:", result.SchemaDigest); Assert.Equal(71, result.SchemaDigest.Length); Assert.Equal(before, db.Hash());
        Assert.Equal(4, db.Inspect(Source(browser), PrivacyWindow.Create(PrivacyTimeRange.AllTime, Now)).Count);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void CookieFiniteRangesDoNotGuessZeroOrUnknownAccessTimes(bool firefox)
    {
        var browser = firefox ? PrivacyBrowser.Firefox : PrivacyBrowser.Edge; var (start, end) = Window.IntegerMicroseconds(!firefox);
        var table = firefox ? "moz_cookies" : "cookies"; var time = firefox ? "lastAccessed" : "last_access_utc";
        using var db = new Database($"CREATE TABLE {table}({time} INTEGER); INSERT INTO {table} VALUES(NULL),(0),(-1),({start - 1}),({start}),({end}),({end + 1});");
        var before = db.Hash(); Assert.Equal(2, db.Inspect(Source(browser, true)).Count);
        Assert.Equal(7, db.Inspect(Source(browser, true), PrivacyWindow.Create(PrivacyTimeRange.AllTime, Now)).Count); Assert.Equal(before, db.Hash());
    }

    [Fact]
    public void FirefoxDownloadVisitsAreExcludedInEveryRange()
    {
        var (start, end) = Window.IntegerMicroseconds(false);
        using var db = new Database("CREATE TABLE moz_places(id INTEGER,foreign_count INTEGER); CREATE TABLE moz_bookmarks(fk INTEGER);" +
            $"CREATE TABLE moz_historyvisits(place_id INTEGER,visit_type INTEGER,visit_date INTEGER); INSERT INTO moz_historyvisits VALUES(1,1,{start}),(1,7,{end}),(1,1,{end + 1});");
        Assert.Equal(1, db.Inspect(Source(PrivacyBrowser.Firefox)).Count);
        Assert.Equal(2, db.Inspect(Source(PrivacyBrowser.Firefox), PrivacyWindow.Create(PrivacyTimeRange.AllTime, Now)).Count);
    }

    [Theory]
    [InlineData("CREATE VIEW private_view AS SELECT * FROM visits;")]
    [InlineData("CREATE TRIGGER private_trigger AFTER DELETE ON visits BEGIN DELETE FROM urls; END;")]
    [InlineData("CREATE TABLE unknown_links(visit_id INTEGER REFERENCES visits(id));")]
    [InlineData("CREATE TABLE unknown_table(id INTEGER PRIMARY KEY); CREATE TABLE visit_source(id INTEGER REFERENCES unknown_table(id));")]
    [InlineData("CREATE TABLE visit_source(wrong_column INTEGER);")]
    [InlineData("CREATE TABLE segment_usage(segment_id INTEGER);")]
    [InlineData("CREATE TABLE visited_links(id INTEGER);")]
    [InlineData("ALTER TABLE urls ADD COLUMN typed_count INTEGER;")]
    public void UnsupportedStructuresStayUnchanged(string addition)
    {
        using var db = new Database(HistorySchema + addition); var before = db.Hash();
        Assert.Equal("privacy_schema_unsupported", Assert.Throws<ShouException>(() => db.Inspect(Source())).Code); Assert.Equal(before, db.Hash());
    }

    [Theory]
    [InlineData("frecency")]
    [InlineData("alt_frecency")]
    [InlineData("recalc_frecency")]
    [InlineData("recalc_alt_frecency")]
    public void FirefoxProprietarySummariesCannotBeTreatedAsSupported(string column)
    {
        using var db = new Database($"CREATE TABLE moz_places(id INTEGER,foreign_count INTEGER,{column} INTEGER); CREATE TABLE moz_bookmarks(fk INTEGER);" +
            "CREATE TABLE moz_historyvisits(place_id INTEGER,visit_type INTEGER,visit_date INTEGER);");
        Assert.Equal("privacy_schema_unsupported", Assert.Throws<ShouException>(() => db.Inspect(Source(PrivacyBrowser.Firefox))).Code);
    }

    [Theory]
    [InlineData("TEXT", "'123'")]
    [InlineData("INTEGER", "'secret-value'")]
    [InlineData("INTEGER", "1.5")]
    [InlineData("INTEGER", "X'0102'")]
    public void TimestampAffinityAndActualValuesMustBeInteger(string type, string value)
    {
        using var db = new Database($"CREATE TABLE cookies(last_access_utc {type}); INSERT INTO cookies VALUES({value});");
        var error = Assert.Throws<ShouException>(() => db.Inspect(Source(cookies: true)));
        Assert.Equal("privacy_schema_unsupported", error.Code); Assert.DoesNotContain("secret-value", error.ToString());
    }

    [Fact]
    public void SchemaDigestBindsStructureWhileCountsBindOnlyTheSelectedRange()
    {
        using var first = new Database(HistorySchema); using var second = new Database(HistorySchema + "CREATE INDEX visit_date ON visits(visit_time);");
        var one = first.Inspect(Source()); var two = second.Inspect(Source());
        Assert.Equal(0, one.Count); Assert.Equal(one.Count, two.Count); Assert.NotEqual(one.SchemaDigest, two.SchemaDigest);
    }

    [Fact]
    public void ReadonlyConnectionCannotDeleteRowsAndFailuresAreRedacted()
    {
        using var db = new Database("CREATE TABLE cookies(last_access_utc INTEGER); INSERT INTO cookies VALUES(1);"); var before = db.Hash();
        using (var connection = new PrivacySqlite(db.Path, readOnly: true, CancellationToken.None))
        {
            Assert.Equal("privacy_database_unavailable", Assert.Throws<ShouException>(() => connection.Execute("DELETE FROM cookies;")).Code);
            var error = Assert.Throws<ShouException>(() => connection.Query("SELECT private_cookie_value FROM missing_table;"));
            Assert.DoesNotContain("private_cookie_value", error.ToString()); Assert.DoesNotContain("missing_table", error.ToString());
        }
        Assert.Equal(before, db.Hash());
    }

    [Fact]
    public void QueryResultAndTextBudgetsAreEnforced()
    {
        using var db = new Database(HistorySchema); using var connection = new PrivacySqlite(db.Path, true, CancellationToken.None);
        Assert.Equal("privacy_schema_unsupported", Assert.Throws<ShouException>(() => connection.Query("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<257) SELECT x FROM n;")).Code);
        Assert.Equal("privacy_schema_unsupported", Assert.Throws<ShouException>(() => connection.Query("SELECT 'a'||hex(zeroblob(32768));")).Code);
    }

    [Fact]
    public void ProgressHandlerCancelsAnActiveQueryWithoutReturningRows()
    {
        using var db = new Database(HistorySchema); using var stop = new CancellationTokenSource();
        using var connection = new PrivacySqlite(db.Path, true, stop.Token); stop.CancelAfter(TimeSpan.FromMilliseconds(20));
        Assert.ThrowsAny<OperationCanceledException>(() => connection.Query("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n) SELECT count(*) FROM n;"));
    }

    [Fact]
    public void MissingDatabaseIsNeverCreated()
    {
        var path = Path.Combine(Path.GetTempPath(), "shou-privacy-missing-" + Guid.NewGuid().ToString("N"));
        Assert.Equal("privacy_database_unavailable", Assert.Throws<ShouException>(() => new PrivacySqlite(path, false, CancellationToken.None)).Code); Assert.False(File.Exists(path));
    }
}
