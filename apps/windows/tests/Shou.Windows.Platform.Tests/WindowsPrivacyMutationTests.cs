using System.Security.Principal;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsPrivacyMutationTests
{
    private static (WindowsPrivacySourcePolicy Policy, PrivacySourceDefinition Source) Source(WindowsFileSystemTests.NativeFixture fixture, bool history = false)
    {
        var root = WindowsPath.Parse(fixture.Root);
        var policy = new WindowsPrivacySourcePolicy(new(root, root.Append("Local"), root.Append("Roaming")));
        var source = policy.Create(PrivacyBrowser.Chromium, "Default", history ? PrivacyDatabaseLocation.History : PrivacyDatabaseLocation.NetworkCookies);
        fixture.Write(Path.GetRelativePath(fixture.Root, source.Path.Value), []);
        return (policy, source);
    }
    private static async Task<PrivacyMutationRequest> Request(WindowsPrivacySourcePolicy policy, PrivacySourceDefinition source, PrivacyWindow window)
    {
        var owner = WindowsIdentity.GetCurrent().User!.Value;
        var observed = await new WindowsPrivacyDatabaseInspection(policy, owner).InspectAsync(source, window, default);
        return new(new(source, PrivacySourceState.Ready, observed.RecordCount, null, observed.SchemaDigest, observed.Evidence), window, owner, DateTimeOffset.UtcNow.AddMinutes(1));
    }

    [WindowsFact]
    public async Task GeneratedCookiesRemoveOnlyTheExactTimeWindowAndPreserveUnrelatedTables()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture();
        var (policy, source) = Source(fixture);
        var window = PrivacyWindow.Create(PrivacyTimeRange.LastHour, DateTimeOffset.UtcNow);
        var bounds = window.IntegerMicroseconds(true);
        using (var database = new PrivacySqlite(source.Path.Value, false, default))
        {
            database.Execute("CREATE TABLE cookies(last_access_utc INTEGER); CREATE TABLE retained(id INTEGER); INSERT INTO retained VALUES(42);");
            _ = database.Query("INSERT INTO cookies VALUES(0),(?1),(?2);", bounds.Start!.Value, bounds.End + 1);
        }
        var request = await Request(policy, source, window);
        var result = await new WindowsPrivacyMutation(policy).ApplyAsync(request, default);
        Assert.True(result.Outcome == PrivacyMutationOutcome.Completed, $"Native privacy result: {result}");
        Assert.Equal(1, result.RemovedRecords);
        using var after = new PrivacySqlite(source.Path.Value, true, default);
        Assert.Equal(2, after.Count("SELECT COUNT(*) FROM cookies;"));
        Assert.Equal(1, after.Count("SELECT COUNT(*) FROM retained WHERE id=42;"));
    }

    [WindowsFact]
    public async Task GeneratedChromiumHistoryMaintainsReferencesAndRetainsOtherVisits()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture();
        var (policy, source) = Source(fixture, history: true);
        var window = PrivacyWindow.Create(PrivacyTimeRange.LastHour, DateTimeOffset.UtcNow);
        var bounds = window.IntegerMicroseconds(true);
        using (var database = new PrivacySqlite(source.Path.Value, false, default))
        {
            database.Execute("CREATE TABLE urls(id INTEGER PRIMARY KEY,visit_count INTEGER,last_visit_time INTEGER); CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER,from_visit INTEGER); CREATE TABLE visit_source(id INTEGER); CREATE TABLE retained(id INTEGER); INSERT INTO urls VALUES(1,2,0),(2,1,0); INSERT INTO visit_source VALUES(1),(2),(3); INSERT INTO retained VALUES(99);");
            _ = database.Query("INSERT INTO visits VALUES(1,1,?1,0),(2,1,?2,1),(3,2,?1,0);", bounds.Start!.Value, bounds.End + 1);
        }
        var result = await new WindowsPrivacyMutation(policy).ApplyAsync(await Request(policy, source, window), default);
        Assert.True(result.Outcome == PrivacyMutationOutcome.Completed, $"Native privacy result: {result}");
        Assert.Equal(2, result.RemovedRecords);
        using var after = new PrivacySqlite(source.Path.Value, true, default);
        Assert.Equal(1, after.Count("SELECT COUNT(*) FROM visits WHERE id=2 AND from_visit=0;"));
        Assert.Equal(1, after.Count("SELECT COUNT(*) FROM urls WHERE id=1 AND visit_count=1;"));
        Assert.Equal(0, after.Count("SELECT COUNT(*) FROM urls WHERE id=2;"));
        Assert.Equal(1, after.Count("SELECT COUNT(*) FROM visit_source WHERE id=2;"));
        Assert.Equal(1, after.Count("SELECT COUNT(*) FROM retained WHERE id=99;"));
    }

    [WindowsFact]
    public async Task ChangedGeneratedDatabaseAndExpiredAuthorizationCannotDeleteRows()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture();
        var (policy, source) = Source(fixture);
        using (var database = new PrivacySqlite(source.Path.Value, false, default)) database.Execute("CREATE TABLE cookies(last_access_utc INTEGER); INSERT INTO cookies VALUES(1);");
        var request = await Request(policy, source, PrivacyWindow.Create(PrivacyTimeRange.AllTime, DateTimeOffset.UtcNow));
        using (var database = new PrivacySqlite(source.Path.Value, false, default)) database.Execute("INSERT INTO cookies VALUES(2);");
        var changed = await new WindowsPrivacyMutation(policy).ApplyAsync(request, default);
        Assert.NotEqual(PrivacyMutationOutcome.Completed, changed.Outcome);
        var fresh = await Request(policy, source, request.Window);
        var expired = await new WindowsPrivacyMutation(policy).ApplyAsync(fresh with { AuthorizationExpiresAt = DateTimeOffset.UtcNow.AddSeconds(-1) }, default);
        Assert.NotEqual(PrivacyMutationOutcome.Completed, expired.Outcome);
        using var after = new PrivacySqlite(source.Path.Value, true, default);
        Assert.Equal(2, after.Count("SELECT COUNT(*) FROM cookies;"));
    }

    [WindowsFact]
    public async Task ExistingNonemptyRollbackJournalIsRejectedBeforeInspectionOrMutation()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture();
        var (policy, source) = Source(fixture);
        using (var database = new PrivacySqlite(source.Path.Value, false, default))
            database.Execute("CREATE TABLE cookies(last_access_utc INTEGER); INSERT INTO cookies VALUES(1);");
        var request = await Request(policy, source, PrivacyWindow.Create(PrivacyTimeRange.AllTime, DateTimeOffset.UtcNow));
        var before = File.ReadAllBytes(source.Path.Value);
        fixture.Write(Path.GetRelativePath(fixture.Root, source.Path.Value + "-journal"), new byte[] { 1, 2, 3, 4 });
        var error = await Assert.ThrowsAsync<ShouException>(() => Request(policy, source, request.Window));
        Assert.Equal("privacy_identity_unavailable", error.Code);
        var result = await new WindowsPrivacyMutation(policy).ApplyAsync(request, default);
        Assert.Equal(PrivacyMutationOutcome.NotStarted, result.Outcome);
        Assert.Equal(before, File.ReadAllBytes(source.Path.Value));
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, File.ReadAllBytes(source.Path.Value + "-journal"));
    }

    [WindowsFact]
    public async Task MissingGeneratedSourceIsNotStartedAndCannotReportAnUnknownMutation()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture();
        var (policy, source) = Source(fixture);
        using (var database = new PrivacySqlite(source.Path.Value, false, default)) database.Execute("CREATE TABLE cookies(last_access_utc INTEGER); INSERT INTO cookies VALUES(1);");
        var request = await Request(policy, source, PrivacyWindow.Create(PrivacyTimeRange.AllTime, DateTimeOffset.UtcNow));
        File.Delete(source.Path.Value);
        var result = await new WindowsPrivacyMutation(policy).ApplyAsync(request, default);
        Assert.Equal(PrivacyMutationOutcome.NotStarted, result.Outcome);
        Assert.Equal(0, result.RemovedRecords);
    }

    [WindowsFact]
    public void CancelledTransactionCanRollbackWithoutItsProgressCallbackInterruptingCleanup()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture();
        var (_, source) = Source(fixture);
        using var cancellation = new CancellationTokenSource();
        using (var database = new PrivacySqlite(source.Path.Value, false, cancellation.Token))
        {
            database.Execute("CREATE TABLE cookies(last_access_utc INTEGER); INSERT INTO cookies VALUES(1); BEGIN IMMEDIATE; DELETE FROM cookies;");
            cancellation.Cancel();
            Assert.True(database.Rollback());
        }
        using var after = new PrivacySqlite(source.Path.Value, true, default);
        Assert.Equal(1, after.Count("SELECT COUNT(*) FROM cookies;"));
    }

    [WindowsFact]
    public async Task GeneratedFirefoxHistoryRetainsBookmarksAndExcludedVisitTypes()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture();
        var root = WindowsPath.Parse(fixture.Root);
        var policy = new WindowsPrivacySourcePolicy(new(root, root.Append("Local"), root.Append("Roaming")));
        var source = policy.Create(PrivacyBrowser.Firefox, "generated.default", PrivacyDatabaseLocation.FirefoxHistory);
        fixture.Write(Path.GetRelativePath(fixture.Root, source.Path.Value), []);
        using (var database = new PrivacySqlite(source.Path.Value, false, default))
            database.Execute("CREATE TABLE moz_places(id INTEGER PRIMARY KEY,foreign_count INTEGER,visit_count INTEGER,last_visit_date INTEGER); CREATE TABLE moz_historyvisits(place_id INTEGER,visit_type INTEGER,visit_date INTEGER); CREATE TABLE moz_bookmarks(fk INTEGER); INSERT INTO moz_places VALUES(1,1,1,1),(2,0,1,1),(3,0,1,1); INSERT INTO moz_historyvisits VALUES(1,1,1),(2,1,1),(3,7,1); INSERT INTO moz_bookmarks VALUES(1);");
        var result = await new WindowsPrivacyMutation(policy).ApplyAsync(await Request(policy, source, PrivacyWindow.Create(PrivacyTimeRange.AllTime, DateTimeOffset.UtcNow)), default);
        var browserProcesses = WindowsProcessInventory.ReadNames(default).Processes
            .Where(process => process.ExecutableName.Equals("firefox.exe", StringComparison.OrdinalIgnoreCase))
            .Select(process => $"{process.ProcessId}:{process.ExecutableName}");
        Assert.True(result.Outcome == PrivacyMutationOutcome.Completed, $"Native privacy result: {result}; current Firefox observations: {string.Join(',', browserProcesses)}");
        Assert.Equal(2, result.RemovedRecords);
        using var after = new PrivacySqlite(source.Path.Value, true, default);
        Assert.Equal(1, after.Count("SELECT COUNT(*) FROM moz_bookmarks WHERE fk=1;"));
        Assert.Equal(1, after.Count("SELECT COUNT(*) FROM moz_places WHERE id=1 AND visit_count=0;"));
        Assert.Equal(0, after.Count("SELECT COUNT(*) FROM moz_places WHERE id=2;"));
        Assert.Equal(1, after.Count("SELECT COUNT(*) FROM moz_historyvisits WHERE place_id=3 AND visit_type=7;"));
    }
}
