using System.Collections.Immutable;

namespace Shou.Windows.Core;

public sealed record ApplicationShortcutReview(FileEntry File, FileEntry Parent, WindowsPath Target, string ContentDigest, DateTimeOffset ObservedAt);
public sealed record ApplicationShortcutCatalog(ImmutableArray<ApplicationShortcutReview> Items, ImmutableArray<ScanIssue> Issues);

/// <summary>Only fixed current-user shortcut sources; an inaccessible target is never evidence of absence.</summary>
public interface IApplicationShortcutInspector
{
    ImmutableArray<WindowsPath> Roots { get; }
    Task<ApplicationShortcutReview> InspectAsync(WindowsPath path, CancellationToken token);
}

public sealed class ApplicationShortcutService(IApplicationShortcutInspector inspector, IWindowsFileSystem files, TimeProvider? timeProvider = null)
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    public async Task<ApplicationShortcutCatalog> ReadAsync(CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(10));
        var found = ImmutableArray.CreateBuilder<ApplicationShortcutReview>();
        var issues = ImmutableArray.CreateBuilder<ScanIssue>();
        var visited = new HashSet<WindowsPath>();
        var count = 0;
        foreach (var root in inspector.Roots.Distinct())
        {
            try { await Visit(root, 0); }
            catch (ShouException error) when (error.Code == "not_found") { }
            catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
            { issues.Add(new(root, error is ShouException known ? known.Code : "permission_denied")); }
            catch (OperationCanceledException) when (!token.IsCancellationRequested) { issues.Add(new(root, "time_limit")); break; }
        }
        token.ThrowIfCancellationRequested();
        return new(found.ToImmutable(), issues.ToImmutable());

        async Task Visit(WindowsPath directory, int depth)
        {
            deadline.Token.ThrowIfCancellationRequested();
            if (++count > 2000 || depth > 8) throw new ShouException("resource_limit", "Shortcut discovery reached its fixed budget.");
            if (!visited.Add(directory)) return;
            var parent = await files.InspectAsync(directory, deadline.Token);
            if (parent.Kind != EntryKind.Directory) throw new ShouException("unsafe_path", "Shortcut sources must be real directories.");
            await foreach (var child in files.ReadDirectoryAsync(directory, deadline.Token))
            {
                if (++count > 2000) throw new ShouException("resource_limit", "Shortcut discovery reached its fixed budget.");
                if (child.Entry is not { } entry) { issues.Add(new(child.Path, child.ErrorCode ?? "io_error")); continue; }
                if (entry.Path != child.Path || entry.Path.Parent != directory) throw new ShouException("unsafe_path", "A shortcut source returned an unrelated child.");
                if (entry.Kind == EntryKind.Directory) await Visit(entry.Path, depth + 1);
                else if (entry.Path.Name.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase))
                {
                    try { found.Add(await inspector.InspectAsync(entry.Path, deadline.Token)); }
                    catch (ShouException error) when (error.Code == "shortcut_target_present") { }
                    catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
                    { issues.Add(new(entry.Path, error is ShouException known ? known.Code : "permission_denied")); }
                }
            }
        }
    }

    public async Task<ScanSnapshot> SnapshotAsync(ApplicationShortcutReview expected, CancellationToken token)
    {
        if (expected.ObservedAt > clock.GetUtcNow() || clock.GetUtcNow() - expected.ObservedAt >= TimeSpan.FromMinutes(15)) throw Stale();
        var current = await inspector.InspectAsync(expected.File.Path, token);
        if (current.File != expected.File || current.Parent.Identity != expected.Parent.Identity || current.Target != expected.Target ||
            current.ContentDigest != expected.ContentDigest || current.File.Kind != EntryKind.File || current.File.LinkCount != 1 ||
            !current.File.Path.Name.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase) || current.File.Path.Parent != current.Parent.Path ||
            !inspector.Roots.Any(root => current.File.Path.IsWithin(root, includeRoot: false))) throw Stale();
        // The parent is context only. Its other children and the shortcut target never enter this manifest.
        return new(RecordKey.New("scan"), current.Parent.Path, current.Parent.Identity, clock.GetUtcNow(), ScanState.Complete,
            [new(current.Parent, 0), new(current.File, current.File.AllocatedBytes)], [], []);
    }
    private static ShouException Stale() => new("plan_stale", "The shortcut changed. Check this application again.");
}
