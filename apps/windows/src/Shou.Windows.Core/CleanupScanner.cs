using System.Collections.Immutable;

namespace Shou.Windows.Core;

/// <summary>Discover rule targets first, then divide the remaining budget between their exact trees.</summary>
public sealed class CleanupScanner(IWindowsFileSystem files, TimeProvider? timeProvider = null) : ICleanupScanner
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly StorageScanner full = new(files, timeProvider);
    private static readonly HashSet<string> PrunedNames = new(StringComparer.OrdinalIgnoreCase)
        { ".git", ".hg", ".svn", ".ssh", ".gnupg", ".shou" };

    public Task<ScanSnapshot> ScanAsync(WindowsPath root, ScanBudget budget, IProgress<ScanProgress>? progress, CancellationToken token) =>
        full.ScanAsync(root, budget, progress, token);

    public async Task<ScanSnapshot> ScanCleanupAsync(WindowsPath root, IReadOnlyList<CleanupRule> rules, ScanBudget budget,
        IReadOnlyList<WindowsPath>? selectedTargets, IProgress<ScanProgress>? progress, CancellationToken cancellationToken)
    {
        budget.Validate();
        if (rules.Count == 0) return await full.ScanAsync(root, budget, progress, cancellationToken);
        if (selectedTargets is { Count: 0 or > 256 } || selectedTargets?.Any(path => !path.IsWithin(root, true, false)) == true)
            throw new ShouException("invalid_argument", "Choose exact targets within the registered root.");
        using var deadline = new CancellationTokenSource(budget.Duration, clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var token = linked.Token;
        var started = clock.GetTimestamp();
        var startedUtc = clock.GetUtcNow();
        FileEntry rootEntry;
        try { rootEntry = await files.InspectAsync(root, token); }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        { throw new ShouException("time_limit", "The directory identity could not be read within the scan budget."); }
        if (rootEntry.Path != root || rootEntry.Kind != EntryKind.Directory)
            throw new ShouException("unsupported_location", "Select a local directory without reparse points.");
        var entries = new Dictionary<WindowsPath, FileEntry> { [root] = rootEntry };
        var directoryIdentities = new HashSet<(ulong, string)> { (rootEntry.Identity.VolumeSerialNumber, rootEntry.Identity.FileId) };
        var issues = new List<ScanIssue>();
        var complete = new HashSet<WindowsPath>();
        var targets = new List<FileEntry>();
        var unverifiedBindings = new Dictionary<WindowsPath, FileEntry>();
        var queue = new Queue<(FileEntry Entry, int Depth)>();
        queue.Enqueue((rootEntry, 0));
        var markers = rules.SelectMany(rule => rule.ParentMarkers).Distinct(StringComparer.Ordinal).ToArray();
        var work = 1;
        var discoveryLimit = Math.Max(1, budget.MaxEntries / 2);
        TimeSpan Remaining() => budget.Duration - clock.GetElapsedTime(started);
        TimeSpan DiscoveryRemaining() => budget.Duration / 2 - clock.GetElapsedTime(started);
        void Issue(WindowsPath path, string code) => issues.Add(new(path, code));
        List<bool> Cases(WindowsPath path)
        {
            var result = new List<bool>();
            for (var parent = path.Parent; parent is not null && parent.IsWithin(root, true); parent = parent.Parent)
            {
                result.Add(entries[parent].IsCaseSensitive);
                if (parent == root) break;
            }
            result.Reverse();
            return result;
        }
        bool Accept(FileEntry entry, FileEntry parent)
        {
            if (entry.Path.Parent != parent.Path || entry.Identity.VolumeSerialNumber != rootEntry.Identity.VolumeSerialNumber ||
                entry.LogicalBytes < 0 || entry.AllocatedBytes < 0)
            { Issue(parent.Path, "unsupported_metadata"); return false; }
            return true;
        }
        try
        {
            while (queue.TryDequeue(out var item))
            {
                token.ThrowIfCancellationRequested();
                if (work >= discoveryLimit || DiscoveryRemaining() <= TimeSpan.Zero)
                { Issue(item.Entry.Path, work >= discoveryLimit ? "entry_limit" : "time_limit"); break; }
                var parent = item.Entry;
                if (item.Depth >= budget.MaxDepth) { Issue(parent.Path, "depth_limit"); continue; }
                var relative = parent.Path.RelativeTo(root, true);
                var cases = parent.Path == root ? new List<bool>() : Cases(parent.Path);
                var applicable = rules.Where(rule => item.Depth < rule.MaxDiscoveryDepth).ToArray();
                var names = new HashSet<string>(parent.IsCaseSensitive ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase);
                var priority = selectedTargets is null
                    ? applicable.SelectMany(rule => rule.Patterns.SelectMany(pattern => pattern.LiteralChildren(relative, cases)))
                    : selectedTargets.Where(path => path.IsWithin(parent.Path, true, false))
                        .Select(path => path.RelativeTo(parent.Path, true).Split('/')[0]);
                var children = new List<FileEntry>();
                var quota = Math.Max(1, (discoveryLimit - work) / Math.Max(2, queue.Count + 1));
                var discoveryDuration = DiscoveryRemaining() / (queue.Count + 1);
                if (discoveryDuration <= TimeSpan.Zero) { Issue(parent.Path, "time_limit"); break; }
                using var local = CancellationTokenSource.CreateLinkedTokenSource(token);
                local.CancelAfter(discoveryDuration);
                try
                {
                    if (await files.InspectAsync(parent.Path, local.Token) != parent)
                    { Issue(parent.Path, "directory_changed"); continue; }
                    foreach (var name in priority.Concat(markers).Distinct(names.Comparer).Order(StringComparer.Ordinal))
                    {
                        local.Token.ThrowIfCancellationRequested();
                        if (work >= discoveryLimit) { Issue(parent.Path, "entry_limit"); break; }
                        try { WindowsPath.ValidateComponent(name); }
                        catch (ShouException) { continue; }
                        names.Add(name);
                        work++;
                        try
                        {
                            var entry = await files.InspectAsync(parent.Path.Append(name), local.Token);
                            if (Accept(entry, parent)) children.Add(entry);
                        }
                        catch (ShouException error) when (error.Code == "not_found") { }
                        catch (ShouException error) { Issue(parent.Path.Append(name), error.Code); }
                        catch (UnauthorizedAccessException) { Issue(parent.Path.Append(name), "permission_denied"); }
                        catch (IOException) { Issue(parent.Path.Append(name), "read_failed"); }
                    }
                    if (selectedTargets is null && applicable.Any(rule => rule.Patterns.Any(pattern => pattern.RequiresEnumeration(relative, cases))))
                    {
                        var observed = 0;
                        await foreach (var child in files.ReadDirectoryAsync(parent.Path, local.Token).WithCancellation(local.Token))
                        {
                            local.Token.ThrowIfCancellationRequested();
                            if (work >= discoveryLimit || observed >= quota)
                            { Issue(parent.Path, "entry_limit"); break; }
                            work++; observed++;
                            if (child.Path.Parent != parent.Path) { Issue(parent.Path, "invalid_directory_entry"); continue; }
                            if (!names.Add(child.Path.Name)) continue;
                            if (child.Entry is { } found && child.ErrorCode is null && found.Path == child.Path)
                            { if (Accept(found, parent)) children.Add(found); }
                            else Issue(child.Path, child.ErrorCode ?? "invalid_directory_entry");
                        }
                    }
                    if (await files.InspectAsync(parent.Path, local.Token) != parent)
                    { Issue(parent.Path, "directory_changed"); continue; }
                }
                catch (OperationCanceledException) when (!token.IsCancellationRequested) { Issue(parent.Path, "time_limit"); }
                catch (ShouException error) { Issue(parent.Path, error.Code); }
                catch (UnauthorizedAccessException) { Issue(parent.Path, "permission_denied"); }
                catch (IOException) { Issue(parent.Path, "read_failed"); }
                foreach (var child in children)
                {
                    if (markers.Contains(child.Path.Name, names.Comparer)) entries[child.Path] = child;
                    if (child.Kind is EntryKind.ReparsePoint or EntryKind.Unsupported)
                    { Issue(child.Path, "unsupported_entry"); continue; }
                    if (child.Kind != EntryKind.Directory || PrunedNames.Contains(child.Path.Name)) continue;
                    var childRelative = child.Path.RelativeTo(root, true);
                    var childCases = cases.Append(parent.IsCaseSensitive).ToArray();
                    var target = selectedTargets is null
                        ? applicable.Any(rule => rule.Patterns.Any(pattern => pattern.Matches(childRelative, childCases)))
                        : selectedTargets.Contains(child.Path);
                    var descend = selectedTargets is null
                        ? applicable.Any(rule => item.Depth + 1 < rule.MaxDiscoveryDepth && rule.Patterns.Any(pattern => pattern.CouldMatchDescendant(childRelative, childCases)))
                        : selectedTargets.Any(path => path.IsWithin(child.Path, true, false));
                    if (!target && !descend) continue;
                    if (!directoryIdentities.Add((child.Identity.VolumeSerialNumber, child.Identity.FileId)))
                    { Issue(child.Path, "duplicate_directory_identity"); continue; }
                    entries[child.Path] = child;
                    if (target) targets.Add(child);
                    else queue.Enqueue((child, item.Depth + 1));
                }
                progress?.Report(new(work, parent.Path));
            }
            var bindings = entries.Values.ToArray();
            foreach (var binding in bindings) unverifiedBindings[binding.Path] = binding;
            targets = targets.DistinctBy(entry => entry.Path).OrderBy(entry => entry.Path.Value, StringComparer.Ordinal).ToList();
            for (var index = 0; index < targets.Count; index++)
            {
                token.ThrowIfCancellationRequested();
                var target = targets[index];
                var depth = target.Path.RelativeTo(root, true).Split('/').Length;
                var quota = (budget.MaxEntries - work) / (targets.Count - index);
                var duration = Remaining() / (targets.Count - index + 1);
                if (quota < 1 || duration <= TimeSpan.Zero || depth >= budget.MaxDepth)
                { Issue(target.Path, depth >= budget.MaxDepth ? "depth_limit" : quota < 1 ? "entry_limit" : "time_limit"); continue; }
                try
                {
                    var tree = await full.ScanAsync(target.Path, new(quota, budget.MaxDepth - depth, duration), progress, token);
                    work += tree.IsComplete ? tree.Entries.Length : quota;
                    if (tree.RootIdentity != target.Identity || tree.Entries.FirstOrDefault()?.Entry != target)
                    { Issue(target.Path, "directory_changed"); continue; }
                    foreach (var measured in tree.Entries) entries[measured.Entry.Path] = measured.Entry;
                    issues.AddRange(tree.Issues);
                    foreach (var path in tree.CompletedDirectories) complete.Add(path);
                }
                catch (ShouException error) { work += quota; Issue(target.Path, error.Code); }
                catch (UnauthorizedAccessException) { work += quota; Issue(target.Path, "permission_denied"); }
                catch (IOException) { work += quota; Issue(target.Path, "read_failed"); }
            }
            // Recheck context after all target measurements; a changed ancestor invalidates every dependent target.
            foreach (var binding in bindings)
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    if (await files.InspectAsync(binding.Path, token) == binding)
                    { unverifiedBindings.Remove(binding.Path); continue; }
                    Issue(binding.Path, "directory_changed");
                }
                catch (ShouException error) { Issue(binding.Path, error.Code); }
                catch (UnauthorizedAccessException) { Issue(binding.Path, "permission_denied"); }
                catch (IOException) { Issue(binding.Path, "read_failed"); }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        { Issue(root, cancellationToken.IsCancellationRequested ? "cancelled" : "time_limit"); }
        // Issues under a target invalidate that target; unrelated discovery gaps do not erase its positive coverage.
        var incompleteAncestors = new HashSet<WindowsPath>();
        foreach (var issue in issues)
            for (var path = issue.Path; path is not null && path.IsWithin(root, true); path = path.Parent)
            {
                incompleteAncestors.Add(path);
                if (path == root) break;
            }
        var invalidContext = unverifiedBindings.Values.Select(binding => binding.Kind == EntryKind.Directory ? binding.Path : binding.Path.Parent!).ToHashSet();
        complete.RemoveWhere(path =>
        {
            if (incompleteAncestors.Contains(path)) return true;
            for (var parent = path; parent is not null && parent.IsWithin(root, true); parent = parent.Parent)
            {
                if (invalidContext.Contains(parent)) return true;
                if (parent == root) break;
            }
            return false;
        });
        var identities = new HashSet<(ulong, string)>();
        var measuredEntries = entries.Values.OrderBy(entry => entry.Path.Value, StringComparer.Ordinal)
            .Select(entry => new MeasuredEntry(entry, identities.Add((entry.Identity.VolumeSerialNumber, entry.Identity.FileId)) ? entry.AllocatedBytes : 0)).ToImmutableArray();
        return new("scan_" + Guid.NewGuid().ToString("N"), root, rootEntry.Identity, startedUtc,
            cancellationToken.IsCancellationRequested ? ScanState.Cancelled : issues.Count > 0 ? ScanState.Partial : ScanState.Complete,
            measuredEntries, issues.Distinct().ToImmutableArray(), complete.OrderBy(path => path.Value, StringComparer.Ordinal).ToImmutableArray(), ScanScope.RuleTargets);
    }
}
