using System.Security.Principal;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Fixed browser databases only; one verified immediate transaction per exact source.</summary>
public sealed class WindowsPrivacyMutation(WindowsPrivacySourcePolicy policy) : IPrivacyMutation
{
    public bool Available => NativeWindowsSupport.IsSupported;
    public Task<PrivacyMutationResult> ApplyAsync(PrivacyMutationRequest request, CancellationToken token)
    {
        if (!Available) return Task.FromResult(new PrivacyMutationResult(PrivacyMutationOutcome.NotStarted, 0, "unsupported_capability"));
        return NativeOperationScheduler.RunToCompletionAsync(() => Apply(request, token), token);
    }
    private PrivacyMutationResult Apply(PrivacyMutationRequest request, CancellationToken token)
    {
        var source = request.Source.Source;
        _ = policy.Validate(source); request.Window.Validate();
        using var actor = WindowsIdentity.GetCurrent();
        if (actor.User?.Value != request.OwnerSid || request.Source.State != PrivacySourceState.Ready || request.Source.RecordCount is not > 0)
            return new(PrivacyMutationOutcome.NotStarted, 0, "privacy_identity_unavailable");
        void Check()
        {
            token.ThrowIfCancellationRequested();
            if (DateTimeOffset.UtcNow >= request.AuthorizationExpiresAt) throw new ShouException("plan_stale", "The exact privacy authorization expired.");
            var inventory = WindowsProcessInventory.ReadNames(token);
            var name = source.Browser switch { PrivacyBrowser.Firefox => "firefox.exe", PrivacyBrowser.Edge => "msedge.exe", PrivacyBrowser.Brave => "brave.exe", _ => "chrome.exe" };
            if (!inventory.Complete) throw new ShouException("privacy_activity_unknown", "Browser activity could not be verified.");
            if (inventory.Processes.Any(process => !process.Exited && string.Equals(process.ExecutableName, name, StringComparison.OrdinalIgnoreCase)))
                throw new ShouException("privacy_browser_running", "Close the browser and review a fresh scan.");
        }
        PrivacySqlite? database = null;
        var transaction = false; var commitAttempted = false;
        try
        {
            Check();
            using var before = WindowsPrivacyDatabaseInspection.SourceAccess.Acquire(policy, source, request.OwnerSid, token, mutation: true);
            if (!before.Evidence.SequenceEqual(request.Source.Evidence)) return new(PrivacyMutationOutcome.NotStarted, 0, "source_changed");
            database = new PrivacySqlite(WindowsFileSystem.Extended(source.Path), readOnly: false, token);
            Check(); database.Execute("BEGIN IMMEDIATE;"); transaction = true;
            var observed = PrivacyDatabaseInspection.Inspect(database, source, request.Window);
            if (observed.Count != request.Source.RecordCount || observed.SchemaDigest != request.Source.SchemaDigest)
                throw new ShouException("source_changed", "The exact database count or schema changed.");
            using (var current = WindowsPrivacyDatabaseInspection.SourceAccess.Acquire(policy, source, request.OwnerSid, token, mutation: true))
                if (!before.Evidence.SequenceEqual(current.Evidence)) throw new ShouException("source_changed", "Privacy file evidence changed before mutation.");
            Check(); Remove(database, source, request.Window);
            if (PrivacyDatabaseInspection.Inspect(database, source, request.Window).Count != 0)
                throw new ShouException("privacy_database_unavailable", "The selected aggregate remains; rollback is required.");
            using (var current = WindowsPrivacyDatabaseInspection.SourceAccess.Acquire(policy, source, request.OwnerSid, token, mutation: true, transactionJournal: true))
                foreach (var original in before.Evidence)
                    if (!current.Evidence.Any(value => value.Entry.Path == original.Entry.Path && value.Entry.Identity == original.Entry.Identity && value.SecurityDigest == original.SecurityDigest))
                        throw new ShouException("source_changed", "Privacy identity or permissions changed during mutation.");
            Check(); commitAttempted = true; database.Execute("COMMIT;"); transaction = false;
            return new(PrivacyMutationOutcome.Completed, observed.Count);
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            if (commitAttempted) return new(PrivacyMutationOutcome.Unknown, Reason: "native_result_unknown");
            var rolledBack = !transaction || database?.Rollback() == true;
            if (!rolledBack) return new(PrivacyMutationOutcome.Unknown, Reason: "native_result_unknown");
            return new(error is OperationCanceledException ? PrivacyMutationOutcome.Cancelled : transaction ? PrivacyMutationOutcome.RolledBack : PrivacyMutationOutcome.NotStarted,
                0, error is ShouException known ? known.Code : error is OperationCanceledException ? "cancelled" : "privacy_database_unavailable");
        }
        finally { database?.Dispose(); }
    }

    private static void Remove(PrivacySqlite database, PrivacySourceDefinition source, PrivacyWindow window)
    {
        var firefox = source.Browser == PrivacyBrowser.Firefox;
        var history = source.Kind == PrivacyDataKind.History;
        var table = history ? firefox ? "moz_historyvisits" : "visits" : firefox ? "moz_cookies" : "cookies";
        var time = history ? firefox ? "visit_date" : "visit_time" : firefox ? "lastAccessed" : "last_access_utc";
        var filter = firefox && history ? "visit_type <> 7" : "1=1";
        var bounds = window.IntegerMicroseconds(!firefox);
        object[] arguments = [];
        if (bounds.Start is { } start) { filter += $" AND {time} >= ?1 AND {time} <= ?2"; if (!history) filter += $" AND {time} > 0"; arguments = [start, bounds.End]; }
        void Filtered(string sql) => _ = database.Query(sql, arguments);
        bool Exists(string name) => database.Count("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1;", name) == 1;
        bool Column(string name, string column) => database.Query("SELECT name FROM pragma_table_info(?1);", name).Any(row => Equals(row[0], column));
        void Optional(string name, string sql) { if (Exists(name)) database.Execute(sql); }
        if (!history) { Filtered($"DELETE FROM {table} WHERE {filter};"); return; }
        if (firefox)
        {
            Filtered($"CREATE TEMP TABLE shou_privacy_places AS SELECT DISTINCT place_id FROM moz_historyvisits WHERE {filter};");
            Filtered($"DELETE FROM moz_historyvisits WHERE {filter};");
            database.Execute("DELETE FROM moz_places WHERE id IN (SELECT place_id FROM shou_privacy_places) AND foreign_count=0 AND NOT EXISTS (SELECT 1 FROM moz_historyvisits WHERE place_id=moz_places.id) AND NOT EXISTS (SELECT 1 FROM moz_bookmarks WHERE fk=moz_places.id);");
            foreach (var (column, value) in new[] { ("visit_count", "COUNT(*)"), ("last_visit_date", "MAX(visit_date)") })
                if (Column("moz_places", column)) database.Execute($"UPDATE moz_places SET {column}=(SELECT {value} FROM moz_historyvisits WHERE place_id=moz_places.id AND visit_type<>7) WHERE id IN (SELECT place_id FROM shou_privacy_places);");
            return;
        }
        Filtered($"CREATE TEMP TABLE shou_privacy_visits AS SELECT id,url FROM visits WHERE {filter};");
        Optional("visited_links", "CREATE TEMP TABLE shou_privacy_links AS SELECT DISTINCT visited_link_id AS id FROM visits WHERE id IN (SELECT id FROM shou_privacy_visits);");
        Optional("clusters_and_visits", "CREATE TEMP TABLE shou_privacy_clusters AS SELECT DISTINCT cluster_id FROM clusters_and_visits WHERE visit_id IN (SELECT id FROM shou_privacy_visits);");
        Optional("visit_source", "DELETE FROM visit_source WHERE id IN (SELECT id FROM shou_privacy_visits);");
        foreach (var name in new[] { "content_annotations", "context_annotations", "clusters_and_visits" })
            Optional(name, $"DELETE FROM {name} WHERE visit_id IN (SELECT id FROM shou_privacy_visits);");
        Optional("cluster_visit_duplicates", "DELETE FROM cluster_visit_duplicates WHERE visit_id IN (SELECT id FROM shou_privacy_visits) OR duplicate_visit_id IN (SELECT id FROM shou_privacy_visits);");
        foreach (var column in new[] { "from_visit", "opener_visit" })
            if (Column("visits", column)) database.Execute($"UPDATE visits SET {column}=0 WHERE {column} IN (SELECT id FROM shou_privacy_visits);");
        database.Execute("DELETE FROM visits WHERE id IN (SELECT id FROM shou_privacy_visits);");
        Optional("visited_links", "DELETE FROM visited_links WHERE id IN (SELECT id FROM shou_privacy_links) AND NOT EXISTS (SELECT 1 FROM visits WHERE visited_link_id=visited_links.id);");
        if (Exists("segments"))
        {
            Optional("segment_usage", "DELETE FROM segment_usage WHERE segment_id IN (SELECT id FROM segments WHERE url_id IN (SELECT url FROM shou_privacy_visits) AND NOT EXISTS (SELECT 1 FROM visits WHERE url=segments.url_id));");
            database.Execute("DELETE FROM segments WHERE url_id IN (SELECT url FROM shou_privacy_visits) AND NOT EXISTS (SELECT 1 FROM visits WHERE url=segments.url_id);");
        }
        Optional("keyword_search_terms", "DELETE FROM keyword_search_terms WHERE url_id IN (SELECT url FROM shou_privacy_visits) AND NOT EXISTS (SELECT 1 FROM visits WHERE url=keyword_search_terms.url_id);");
        database.Execute("DELETE FROM urls WHERE id IN (SELECT url FROM shou_privacy_visits) AND NOT EXISTS (SELECT 1 FROM visits WHERE url=urls.id);");
        foreach (var (column, value) in new[] { ("visit_count", "COUNT(*)"), ("last_visit_time", "MAX(visit_time)"), ("typed_count", "SUM(CASE WHEN (transition & 255)=1 THEN 1 ELSE 0 END)") })
            if (Column("urls", column)) database.Execute($"UPDATE urls SET {column}=(SELECT {value} FROM visits WHERE url=urls.id) WHERE id IN (SELECT url FROM shou_privacy_visits);");
        if (Exists("clusters") && Exists("clusters_and_visits")) database.Execute("DELETE FROM clusters WHERE cluster_id IN (SELECT cluster_id FROM shou_privacy_clusters) AND NOT EXISTS (SELECT 1 FROM clusters_and_visits WHERE cluster_id=clusters.cluster_id);");
    }
}
