using System.Diagnostics;
using System.Runtime.InteropServices;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Windows system SQLite. Callers pin verified source files; SQL errors and row contents never enter diagnostics.</summary>
internal sealed class PrivacySqlite : IDisposable
{
    private nint database;
    private readonly CancellationToken token;
    private readonly long started = Stopwatch.GetTimestamp();
    private readonly Native.Progress callback;
    private int operations;
    private bool limited;

    internal PrivacySqlite(string path, bool readOnly, CancellationToken cancellationToken)
    {
        token = cancellationToken;
        callback = CheckProgress;
        token.ThrowIfCancellationRequested();
        if (Native.Version() < 3_031_000) throw new ShouException("privacy_schema_unsupported", "System SQLite lacks the required no-follow opening contract.");
        // OPEN_EXISTING only; URI, extension loading, shared cache and CREATE are never requested.
        if (Native.Open(path, out database, (readOnly ? 1 : 2) | 0x01000000 | 0x00008000, 0) != 0)
        { Dispose(); throw Failure(); }
        try
        {
            _ = Native.BusyTimeout(database, 1000);
            Native.ProgressHandler(database, 1000, callback, 0);
            Execute("PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON; PRAGMA mmap_size=0; PRAGMA cache_size=-2048;");
            if (readOnly) Execute("PRAGMA query_only=ON;");
        }
        catch { Dispose(); throw; }
    }

    private int CheckProgress(nint _)
    {
        limited = ++operations >= 50_000 || Stopwatch.GetElapsedTime(started) >= TimeSpan.FromSeconds(15);
        return token.IsCancellationRequested || limited ? 1 : 0;
    }

    internal void Execute(string sql)
    {
        Check();
        if (Native.Exec(database, sql, 0, 0, 0) != 0) throw Failure();
        Check();
    }
    // A cancelled query must still release its transaction before returning. No caller SQL is accepted.
    internal bool Rollback()
    {
        if (database == 0) return false;
        Native.ProgressHandler(database, 0, null, 0);
        try { return Native.Exec(database, "ROLLBACK;", 0, 0, 0) == 0; }
        finally { Native.ProgressHandler(database, 1000, callback, 0); }
    }

    internal List<object?[]> Query(string sql, params object[] arguments)
    {
        Check();
        var prepared = Native.Prepare(database, sql, -1, out var statement, 0);
        if (prepared != 0 || statement == 0) { if (statement != 0) _ = Native.Finalize(statement); throw Failure(); }
        try
        {
            for (var index = 0; index < arguments.Length; index++)
            {
                var code = arguments[index] switch
                {
                    long value => Native.BindInt64(statement, index + 1, value),
                    string value => Native.BindText(statement, index + 1, value, -1, new nint(-1)),
                    _ => throw new ArgumentException("Only static-schema names and integer boundaries may be bound.", nameof(arguments))
                };
                if (code != 0) throw Failure();
            }
            var rows = new List<object?[]>();
            while (true)
            {
                Check();
                var result = Native.Step(statement);
                if (result == 101) return rows;
                if (result != 100) throw Failure();
                if (rows.Count >= 256) throw Unsupported();
                var count = Native.ColumnCount(statement);
                if (count is < 1 or > 8) throw Unsupported();
                var row = new object?[count];
                for (var index = 0; index < count; index++)
                {
                    row[index] = Native.ColumnType(statement, index) switch
                    {
                        1 => Native.ColumnInt64(statement, index), 3 => ReadText(statement, index), 5 => null, _ => throw Unsupported()
                    };
                }
                rows.Add(row);
            }
        }
        finally { _ = Native.Finalize(statement); }
    }

    internal long Count(string sql, params object[] arguments)
    {
        var rows = Query(sql, arguments);
        return rows.Count == 1 && rows[0].Length == 1 && rows[0][0] is long value && value >= 0 ? value : throw Unsupported();
    }

    private static string ReadText(nint statement, int column)
    {
        var length = Native.ColumnBytes(statement, column);
        if (length is < 0 or > 65_536) throw Unsupported();
        var pointer = Native.ColumnText(statement, column);
        return pointer != 0 ? Marshal.PtrToStringUTF8(pointer, length) ?? throw Unsupported() : throw Unsupported();
    }

    private void Check()
    {
        token.ThrowIfCancellationRequested();
        if (limited || Stopwatch.GetElapsedTime(started) >= TimeSpan.FromSeconds(15)) throw new ShouException("privacy_query_limit", "The privacy aggregate query reached its budget.");
    }
    private ShouException Failure()
    {
        token.ThrowIfCancellationRequested();
        if (limited) return new("privacy_query_limit", "The privacy aggregate query reached its budget.");
        var code = database == 0 ? 0 : Native.ErrorCode(database);
        return new(code is 5 or 6 ? "privacy_database_busy" : "privacy_database_unavailable", "The privacy database is unavailable. Record contents were not logged.");
    }
    internal static ShouException Unsupported() => new("privacy_schema_unsupported", "The browser database structure is unsupported and was preserved.");
    public void Dispose()
    {
        if (database == 0) return;
        Native.ProgressHandler(database, 0, null, 0);
        _ = Native.Close(database);
        database = 0;
    }

    private static class Native
    {
        private const string Library = "winsqlite3.dll";
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int Progress(nint context);
        [DllImport(Library, EntryPoint = "sqlite3_libversion_number", CallingConvention = CallingConvention.Cdecl)] internal static extern int Version();
        [DllImport(Library, EntryPoint = "sqlite3_open_v2", CallingConvention = CallingConvention.Cdecl)] internal static extern int Open([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out nint database, int flags, nint vfs);
        [DllImport(Library, EntryPoint = "sqlite3_close", CallingConvention = CallingConvention.Cdecl)] internal static extern int Close(nint database);
        [DllImport(Library, EntryPoint = "sqlite3_errcode", CallingConvention = CallingConvention.Cdecl)] internal static extern int ErrorCode(nint database);
        [DllImport(Library, EntryPoint = "sqlite3_busy_timeout", CallingConvention = CallingConvention.Cdecl)] internal static extern int BusyTimeout(nint database, int milliseconds);
        [DllImport(Library, EntryPoint = "sqlite3_progress_handler", CallingConvention = CallingConvention.Cdecl)] internal static extern void ProgressHandler(nint database, int instructions, Progress? callback, nint context);
        [DllImport(Library, EntryPoint = "sqlite3_exec", CallingConvention = CallingConvention.Cdecl)] internal static extern int Exec(nint database, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, nint callback, nint context, nint error);
        [DllImport(Library, EntryPoint = "sqlite3_prepare_v2", CallingConvention = CallingConvention.Cdecl)] internal static extern int Prepare(nint database, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int length, out nint statement, nint tail);
        [DllImport(Library, EntryPoint = "sqlite3_bind_int64", CallingConvention = CallingConvention.Cdecl)] internal static extern int BindInt64(nint statement, int index, long value);
        [DllImport(Library, EntryPoint = "sqlite3_bind_text", CallingConvention = CallingConvention.Cdecl)] internal static extern int BindText(nint statement, int index, [MarshalAs(UnmanagedType.LPUTF8Str)] string value, int length, nint destructor);
        [DllImport(Library, EntryPoint = "sqlite3_step", CallingConvention = CallingConvention.Cdecl)] internal static extern int Step(nint statement);
        [DllImport(Library, EntryPoint = "sqlite3_finalize", CallingConvention = CallingConvention.Cdecl)] internal static extern int Finalize(nint statement);
        [DllImport(Library, EntryPoint = "sqlite3_column_count", CallingConvention = CallingConvention.Cdecl)] internal static extern int ColumnCount(nint statement);
        [DllImport(Library, EntryPoint = "sqlite3_column_type", CallingConvention = CallingConvention.Cdecl)] internal static extern int ColumnType(nint statement, int column);
        [DllImport(Library, EntryPoint = "sqlite3_column_int64", CallingConvention = CallingConvention.Cdecl)] internal static extern long ColumnInt64(nint statement, int column);
        [DllImport(Library, EntryPoint = "sqlite3_column_bytes", CallingConvention = CallingConvention.Cdecl)] internal static extern int ColumnBytes(nint statement, int column);
        [DllImport(Library, EntryPoint = "sqlite3_column_text", CallingConvention = CallingConvention.Cdecl)] internal static extern nint ColumnText(nint statement, int column);
    }
}
