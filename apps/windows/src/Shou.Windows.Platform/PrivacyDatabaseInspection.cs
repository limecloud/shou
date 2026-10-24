using System.Security.Cryptography;
using System.Text.Json;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Source-specific schema and aggregate SQL. It neither reads browsing values nor changes database records.</summary>
internal static class PrivacyDatabaseInspection
{
    internal static (long Count, string SchemaDigest) Inspect(string path, PrivacySourceDefinition source, PrivacyWindow window, CancellationToken token)
    {
        window.Validate();
        using var database = new PrivacySqlite(path, readOnly: true, token);
        database.Execute("BEGIN;");
        var observation = Inspect(database, source, window);
        database.Execute("ROLLBACK;");
        return observation;
    }

    internal static (long Count, string SchemaDigest) Inspect(PrivacySqlite database, PrivacySourceDefinition source, PrivacyWindow window)
    {
        window.Validate();
        var schema = database.Query("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name;");
        var tables = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        foreach (var row in schema)
        {
            if (row[0] is not string type || row[1] is not string name || name.Length > 256 || type is not ("table" or "index")) throw PrivacySqlite.Unsupported();
            if (type != "table") continue;
            if (row[3] is not string sql || !sql.TrimStart().StartsWith("CREATE TABLE", StringComparison.OrdinalIgnoreCase)) throw PrivacySqlite.Unsupported();
            var columns = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var column in database.Query("SELECT name,type FROM pragma_table_info(?1) ORDER BY cid;", name))
                if (column[0] is not string columnName || column[1] is not string columnType || columnName.Length > 256 || columnType.Length > 256 ||
                    !columns.TryAdd(columnName, columnType)) throw PrivacySqlite.Unsupported();
            if (!tables.TryAdd(name, columns)) throw PrivacySqlite.Unsupported();
        }
        void Require(string table, params string[] columns)
        {
            if (!tables.TryGetValue(table, out var found) || columns.Any(column => !found.ContainsKey(column))) throw PrivacySqlite.Unsupported();
        }
        string table, time;
        HashSet<string> known;
        if (source.Browser != PrivacyBrowser.Firefox && source.Kind == PrivacyDataKind.History)
        {
            Require("visits", "id", "url", "visit_time"); Require("urls", "id");
            table = "visits"; time = "visit_time";
            known = ["visits", "urls", "visit_source", "content_annotations", "context_annotations", "clusters_and_visits",
                "cluster_visit_duplicates", "keyword_search_terms", "segments", "segment_usage", "clusters", "visited_links"];
            foreach (var (optional, columns) in new (string, string[])[]
            {
                ("visit_source", ["id"]), ("content_annotations", ["visit_id"]), ("context_annotations", ["visit_id"]),
                ("clusters_and_visits", ["cluster_id", "visit_id"]), ("cluster_visit_duplicates", ["visit_id", "duplicate_visit_id"]),
                ("keyword_search_terms", ["url_id"]), ("segments", ["id", "url_id"]), ("segment_usage", ["segment_id"]), ("clusters", ["cluster_id"])
            }) if (tables.ContainsKey(optional)) Require(optional, columns);
            if (tables.ContainsKey("visited_links")) { Require("visited_links", "id"); Require("visits", "visited_link_id"); }
            if (tables["urls"].ContainsKey("typed_count")) Require("visits", "transition");
            if (tables.ContainsKey("segment_usage") && !tables.ContainsKey("segments")) throw PrivacySqlite.Unsupported();
        }
        else if (source.Browser == PrivacyBrowser.Firefox && source.Kind == PrivacyDataKind.History)
        {
            Require("moz_historyvisits", "place_id", "visit_type", "visit_date"); Require("moz_places", "id", "foreign_count"); Require("moz_bookmarks", "fk");
            if (tables["moz_places"].Keys.Any(column => column is "frecency" or "alt_frecency" or "recalc_frecency" or "recalc_alt_frecency")) throw PrivacySqlite.Unsupported();
            table = "moz_historyvisits"; time = "visit_date"; known = ["moz_historyvisits", "moz_places", "moz_bookmarks"];
        }
        else if (source.Browser == PrivacyBrowser.Firefox && source.Kind == PrivacyDataKind.Cookies)
        { Require("moz_cookies", "lastAccessed"); table = "moz_cookies"; time = "lastAccessed"; known = ["moz_cookies"]; }
        else if (source.Kind == PrivacyDataKind.Cookies)
        { Require("cookies", "last_access_utc"); table = "cookies"; time = "last_access_utc"; known = ["cookies"]; }
        else throw PrivacySqlite.Unsupported();

        if (!tables[table][time].Contains("INT", StringComparison.OrdinalIgnoreCase)) throw PrivacySqlite.Unsupported();
        foreach (var name in tables.Keys)
            foreach (var foreign in database.Query("SELECT \"table\" FROM pragma_foreign_key_list(?1);", name))
                if (foreign[0] is not string target || known.Contains(name) != known.Contains(target)) throw PrivacySqlite.Unsupported();

        // The only dynamic SQL identifiers below come from the closed switches above.
        if (database.Count($"SELECT COUNT(*) FROM {table} WHERE {time} IS NOT NULL AND typeof({time}) <> 'integer';") != 0) throw PrivacySqlite.Unsupported();
        var filter = source.Browser == PrivacyBrowser.Firefox && source.Kind == PrivacyDataKind.History ? "visit_type <> 7" : "1=1";
        var boundaries = window.IntegerMicroseconds(source.Browser != PrivacyBrowser.Firefox);
        var arguments = new List<object>();
        if (boundaries.Start is { } start)
        {
            filter += $" AND {time} >= ?1 AND {time} <= ?2";
            if (source.Kind == PrivacyDataKind.Cookies) filter += $" AND {time} > 0";
            arguments.Add(start); arguments.Add(boundaries.End);
        }
        var count = database.Count($"SELECT COUNT(*) FROM {table} WHERE {filter};", arguments.ToArray());
        var schemaDigest = "sha256:" + Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(schema, ContractJson.Options)));
        return (count, schemaDigest);
    }
}
