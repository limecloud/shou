using System.Collections.Immutable;

namespace Shou.Windows.Core;

/// <summary>Bounded traversal; missing or changing evidence can never become complete coverage.</summary>
public sealed class StorageScanner(IWindowsFileSystem fileSystem, TimeProvider? timeProvider = null) : IStorageScanner
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async Task<ScanSnapshot> ScanAsync(WindowsPath root, ScanBudget budget,
        IProgress<ScanProgress>? progress, CancellationToken cancellationToken)
    {
        budget.Validate();
        cancellationToken.ThrowIfCancellationRequested();
        using var deadline = new CancellationTokenSource(budget.Duration, clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var token = linked.Token;
        var started = clock.GetUtcNow();
        FileEntry rootEntry;
        try { rootEntry = await fileSystem.InspectAsync(root, token); }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new ShouException("time_limit", "The directory identity could not be read within the scan budget.");
        }
        if (!rootEntry.Path.SamePath(root) || rootEntry.Kind != EntryKind.Directory)
            throw new ShouException("unsupported_location", "Select a local directory that is not a reparse point.");
        var measured = ImmutableArray.CreateBuilder<MeasuredEntry>();
        var issues = ImmutableArray.CreateBuilder<ScanIssue>();
        var identities = new HashSet<(ulong, string)>();
        var completedEntries = new HashSet<WindowsPath>();
        var completedDirectories = new HashSet<WindowsPath>();
        var pending = new Stack<WorkItem>();
        var observedEntries = 1;
        var lastReportedCount = 0;
        var lastReportTimestamp = 0L;
        var currentPath = root;
        void Report(bool final = false)
        {
            if (progress is null || measured.Count == lastReportedCount) return;
            if (!final && lastReportedCount > 0 && (measured.Count % 128 != 0 ||
                clock.GetElapsedTime(lastReportTimestamp) < TimeSpan.FromMilliseconds(250))) return;
            lastReportedCount = measured.Count;
            lastReportTimestamp = clock.GetTimestamp();
            // A progress consumer cannot invalidate the observed filesystem evidence.
            try { progress.Report(new(lastReportedCount, currentPath)); }
            catch (Exception error) when (error is not OutOfMemoryException) { }
        }
        pending.Push(new(rootEntry, 0));

        try
        {
            while (pending.TryPop(out var item))
            {
                token.ThrowIfCancellationRequested();
                if (item.Children is { } expectedChildren)
                {
                    try
                    {
                        if (await fileSystem.InspectAsync(item.Entry.Path, token) != item.Entry)
                            issues.Add(new(item.Entry.Path, "directory_changed"));
                        else if (item.EnumerationComplete && expectedChildren.All(child => completedEntries.Contains(child.Path)))
                        {
                            completedEntries.Add(item.Entry.Path);
                            completedDirectories.Add(item.Entry.Path);
                        }
                    }
                    catch (ShouException error) { issues.Add(new(item.Entry.Path, error.Code)); }
                    catch (UnauthorizedAccessException) { issues.Add(new(item.Entry.Path, "permission_denied")); }
                    catch (IOException) { issues.Add(new(item.Entry.Path, "read_failed")); }
                    continue;
                }
                if (measured.Count >= budget.MaxEntries)
                {
                    issues.Add(new(item.Entry.Path, "entry_limit"));
                    break;
                }
                var entry = item.Entry;
                if (entry.LogicalBytes < 0 || entry.AllocatedBytes < 0 || entry.Identity.VolumeSerialNumber != rootEntry.Identity.VolumeSerialNumber)
                {
                    issues.Add(new(entry.Path, "unsupported_metadata"));
                    continue;
                }
                var firstLink = identities.Add((entry.Identity.VolumeSerialNumber, entry.Identity.FileId));
                if (!firstLink && entry.Kind == EntryKind.Directory)
                {
                    issues.Add(new(entry.Path, "duplicate_directory_identity"));
                    continue;
                }
                measured.Add(new(entry, firstLink ? entry.AllocatedBytes : 0));
                currentPath = entry.Path;
                Report();
                if (entry.Kind != EntryKind.Directory)
                {
                    if (entry.Kind != EntryKind.File) issues.Add(new(entry.Path, "unsupported_entry"));
                    else
                    {
                        try
                        {
                            if (fileSystem.VerifiesDirectoryEntries || await fileSystem.InspectAsync(entry.Path, token) == entry) completedEntries.Add(entry.Path);
                            else issues.Add(new(entry.Path, "entry_changed"));
                        }
                        catch (ShouException error) { issues.Add(new(entry.Path, error.Code)); }
                        catch (UnauthorizedAccessException) { issues.Add(new(entry.Path, "permission_denied")); }
                        catch (IOException) { issues.Add(new(entry.Path, "read_failed")); }
                    }
                    continue;
                }
                if (item.Depth >= budget.MaxDepth)
                {
                    issues.Add(new(entry.Path, "depth_limit"));
                    continue;
                }
                var children = new List<FileEntry>();
                var localIssueStart = issues.Count;
                var names = new HashSet<string>(entry.IsCaseSensitive ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase);
                try
                {
                    await foreach (var child in fileSystem.ReadDirectoryAsync(entry.Path, token).WithCancellation(token))
                    {
                        token.ThrowIfCancellationRequested();
                        if (observedEntries >= budget.MaxEntries)
                        {
                            issues.Add(new(entry.Path, "entry_limit"));
                            break;
                        }
                        observedEntries++;
                        if (child.Path.Parent is not { } parent || !parent.SamePath(entry.Path, entry.IsCaseSensitive) || !names.Add(child.Path.Name))
                        {
                            issues.Add(new(entry.Path, "invalid_directory_entry"));
                            continue;
                        }
                        if (child.Entry is { } found && child.ErrorCode is null && found.Path == child.Path)
                            children.Add(found);
                        else if (child.Entry is null && child.ErrorCode is { Length: > 0 and <= 80 } code && code.All(c => char.IsAsciiLetterLower(c) || c == '_'))
                            issues.Add(new(child.Path, code));
                        else
                            issues.Add(new(child.Path, "invalid_directory_entry"));
                    }
                }
                catch (ShouException error) { issues.Add(new(entry.Path, error.Code)); }
                catch (UnauthorizedAccessException) { issues.Add(new(entry.Path, "permission_denied")); }
                catch (IOException) { issues.Add(new(entry.Path, "read_failed")); }
                try
                {
                    var current = await fileSystem.InspectAsync(entry.Path, token);
                    if (current != entry)
                    {
                        issues.Add(new(entry.Path, "directory_changed"));
                        continue;
                    }
                    pending.Push(new(entry, item.Depth, children.ToImmutableArray(), issues.Count == localIssueStart));
                    foreach (var child in children.OrderByDescending(child => child.Path.Value, StringComparer.Ordinal))
                        pending.Push(new(child, item.Depth + 1));
                }
                catch (ShouException error) { issues.Add(new(entry.Path, error.Code)); }
                catch (UnauthorizedAccessException) { issues.Add(new(entry.Path, "permission_denied")); }
                catch (IOException) { issues.Add(new(entry.Path, "read_failed")); }
            }
            if (await fileSystem.InspectAsync(root, token) != rootEntry)
            {
                issues.Add(new(root, "directory_changed"));
                completedDirectories.Remove(root);
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            issues.Add(new(root, cancellationToken.IsCancellationRequested ? "cancelled" : "time_limit"));
        }
        catch (ShouException error) { issues.Add(new(root, error.Code)); }
        catch (UnauthorizedAccessException) { issues.Add(new(root, "permission_denied")); }
        catch (IOException) { issues.Add(new(root, "read_failed")); }

        Report(final: true);
        var state = cancellationToken.IsCancellationRequested ? ScanState.Cancelled : issues.Count > 0 ? ScanState.Partial : ScanState.Complete;
        return new("scan_" + Guid.NewGuid().ToString("N"), root, rootEntry.Identity, started, state,
            measured.ToImmutable(), issues.ToImmutable(), completedDirectories.OrderBy(path => path.Value, StringComparer.Ordinal).ToImmutableArray());
    }

    private sealed record WorkItem(FileEntry Entry, int Depth, ImmutableArray<FileEntry>? Children = null, bool EnumerationComplete = false);
}
