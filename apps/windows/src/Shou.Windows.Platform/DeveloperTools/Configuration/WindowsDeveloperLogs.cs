using System.Collections.Immutable;
using System.Text;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed record DeveloperLogTarget(string Path, string Title);
internal interface IDeveloperLogPaths
{
    string ToolId { get; }
    IEnumerable<DeveloperLogTarget> UnderInstallation(string root);
}

public static class WindowsDeveloperLogs
{
    private static readonly IDeveloperLogPaths[] adapters = [new NginxLogPaths(), new MySQLLogPaths(), new RedisLogPaths()];

    public static Task<ImmutableArray<DeveloperLogTarget>> DiscoverAsync(string toolId, IEnumerable<DeveloperToolInstallation> installations,
        IEnumerable<DeveloperService> services, CancellationToken cancellationToken) => Task.Run(() =>
    {
        var candidates = new List<DeveloperLogTarget>();
        foreach (var service in services.Where(row => row.ToolId == toolId))
        {
            if (service.LogPath is { } log) candidates.Add(new(log, "Service Log"));
            if (service.ErrorLogPath is { } error) candidates.Add(new(error, "Startup Output"));
        }
        if (adapters.FirstOrDefault(adapter => adapter.ToolId == toolId) is { } adapter)
            foreach (var installation in installations.Where(row => row.ToolId == toolId))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!System.IO.Path.IsPathFullyQualified(installation.Path)) continue;
                var root = File.Exists(installation.Path) ? System.IO.Path.GetDirectoryName(installation.Path)! : installation.Path;
                candidates.AddRange(adapter.UnderInstallation(root));
            }
        return candidates.Where(row => File.Exists(row.Path)).DistinctBy(row => row.Path, StringComparer.OrdinalIgnoreCase).Take(64).ToImmutableArray();
    }, cancellationToken);

    public static Task<string> ReadTailAsync(WindowsPath path, CancellationToken cancellationToken) => Task.Run(() =>
    {
        cancellationToken.ThrowIfCancellationRequested(); WindowsDeveloperLogCleanup.RequirePath(path);
        using var pinned = WindowsFileSystem.PinPath(path, allowFinalSharedWrites: true);
        var entry = WindowsFileSystem.ReadEntry(path, pinned.Final);
        if (entry.Kind != EntryKind.File || entry.LinkCount != 1) throw new ShouException("developer_log_unavailable", "The log is not a regular file.");
        var offset = Math.Max(0, entry.LogicalBytes - 65536); var bytes = new byte[(int)Math.Min(entry.LogicalBytes, 65536)];
        var count = 0;
        while (count < bytes.Length)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var read = RandomAccess.Read(pinned.Final, bytes.AsSpan(count), offset + count); if (read == 0) break; count += read;
        }
        var content = Encoding.UTF8.GetString(bytes, 0, count);
        if (content.Contains('\0')) throw new ShouException("developer_log_unavailable", "Choose a UTF-8 text log.");
        if (offset > 0) content = content.IndexOf('\n') is var start && start >= 0 ? content[(start + 1)..] : "";
        return string.Join("\n", content.Split('\n').TakeLast(200));
    }, cancellationToken);
}
