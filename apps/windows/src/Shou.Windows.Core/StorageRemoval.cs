using System.Collections.Immutable;

namespace Shou.Windows.Core;

public sealed record StorageRemovalSkip(WindowsPath Path, string Reason);
public sealed record StorageRemovalReview(CleanupPlan? Plan, ImmutableArray<StorageRemovalSkip> SkippedItems);

public sealed partial class CleanupService
{
    /// <summary>Freeze explicitly selected measured objects. This does not register roots or enable rules.</summary>
    public async Task<CleanupPlan> CreateStoragePlanAsync(ScanSnapshot snapshot, IEnumerable<WindowsPath> paths, CancellationToken cancellationToken = default)
    {
        var review = await PrepareStorageRemovalAsync(snapshot, paths, false, cancellationToken);
        return review.Plan ?? throw Input("Choose distinct non-overlapping measured paths below the analysis root.");
    }

    /// <summary>Unavailable selections remain read-only; only fully verified siblings enter the plan.</summary>
    public Task<StorageRemovalReview> ReviewStorageRemovalAsync(ScanSnapshot snapshot, IEnumerable<WindowsPath> paths, CancellationToken cancellationToken = default) =>
        PrepareStorageRemovalAsync(snapshot, paths, true, cancellationToken);

    private async Task<StorageRemovalReview> PrepareStorageRemovalAsync(ScanSnapshot snapshot, IEnumerable<WindowsPath> paths, bool skipUnavailable, CancellationToken cancellationToken)
    {
        if (storageFiles is null) throw new ShouException("unsupported_capability", "Native storage inspection is unavailable.");
        var selected = paths.Take(CleanupRecordCodec.MaximumPlanItems + 1).Distinct().OrderBy(path => path.Value, StringComparer.Ordinal).ToArray();
        if (selected.Length is < 1 or > CleanupRecordCodec.MaximumPlanItems || selected.Any(path => path == snapshot.Root || !path.IsWithin(snapshot.Root, caseSensitive: true)) ||
            selected.Any(path => selected.Any(other => other != path && path.IsWithin(other)))) throw Input("Choose distinct non-overlapping measured paths below the analysis root.");
        RequireSupported(CleanupAction.Permanent);
        await using var lease = await store.AcquireLeaseAsync(cancellationToken);
        var configuration = await ReadConfigurationAsync(lease, cancellationToken);
        var root = await storageFiles.InspectAsync(snapshot.Root, cancellationToken);
        if (root.Kind != EntryKind.Directory || root.Identity != snapshot.RootIdentity) throw Stale();
        var items = ImmutableArray.CreateBuilder<CleanupPlanItem>();
        var skipped = ImmutableArray.CreateBuilder<StorageRemovalSkip>();
        var sources = ImmutableArray.CreateBuilder<CleanupPlanSource>();
        var budget = new ScanBudget(1_000_000, 64, TimeSpan.FromMinutes(2));
        var started = clock.GetTimestamp();
        var reviewedEntries = 0;
        foreach (var path in selected)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var remaining = budget.Duration - clock.GetElapsedTime(started);
            if (remaining <= TimeSpan.Zero) throw new ShouException("time_limit", "Storage review reached its shared deadline.");
            if (reviewedEntries >= budget.MaxEntries) throw new ShouException("resource_limit", "Storage review reached its shared budget.");
            var saved = snapshot.Entries.SingleOrDefault(value => value.Entry.Path == path)?.Entry ?? throw Stale();
            try
            {
                if (saved.Kind == EntryKind.Directory && !snapshot.IsCompleteAt(path) || snapshot.Issues.Any(issue => issue.Path.IsWithin(path) || path.IsWithin(issue.Path)))
                    throw new ShouException("coverage_incomplete", "This folder was not completely scanned.");
                var parent = await storageFiles.InspectAsync(path.Parent!, cancellationToken);
                if (parent.Kind != EntryKind.Directory || parent.Path.IsVolumeRoot) throw Stale();
                if (parent.Identity.OwnerSid != protection.OwnerSid) throw new ShouException("foreign_owner", "This location is not owned by the current account.");
                var source = sources.FirstOrDefault(value => value.Workspace.Path == parent.Path);
                if (source is null)
                {
                    var workspace = new Workspace(RecordKey.New("ws"), "storage-selection-" + sources.Count, parent.Path, parent.Identity, parent.IsCaseSensitive, [], clock.GetUtcNow());
                    source = new(RecordKey.New("scan"), workspace, []);
                    sources.Add(source);
                }
                var manifest = await ReadStorageManifestAsync(path, budget with { MaxEntries = budget.MaxEntries - reviewedEntries, MaxDuration = remaining },
                    cancellationToken, count => reviewedEntries += count);
                var current = manifest[0];
                if (current.Identity != saved.Identity || current.Kind != saved.Kind || current.Kind == EntryKind.File && current != saved) throw Stale();
                RequireStoragePolicy(configuration, source.Workspace, manifest);
                var item = new CleanupPlanItem(RecordKey.New("item"), source.ScanId, RecordKey.New("candidate"), "shou.storage-selection", "1.0.0",
                    path.RelativeTo(parent.Path, caseSensitive: true), path, manifest, [parent], RuleClassifier.ManifestDigest(manifest),
                    manifest.Sum(entry => entry.AllocatedBytes), manifest.Sum(entry => entry.LogicalBytes), "high");
                await RequireIdleAsync(source.Workspace, item, cancellationToken);
                items.Add(item);
            }
            catch (Exception error) when (skipUnavailable && !cancellationToken.IsCancellationRequested && IsUnavailableStorageTarget(error))
            {
                skipped.Add(new(path, Reason(error)));
            }
        }
        cancellationToken.ThrowIfCancellationRequested();
        if (items.Count == 0) return new(null, skipped.ToImmutable());
        var now = clock.GetUtcNow();
        var plan = new CleanupPlan(3, RecordKey.New("plan"), sources.Where(source => items.Any(item => item.ScanId == source.ScanId)).ToImmutableArray(), budget, configuration.Revision, configurationCodec.Digest(configuration),
            now, now + CleanupRecordCodec.PlanLifetime, CleanupAction.Permanent, items.ToImmutable(), "");
        plan = plan with { Digest = CleanupRecordCodec.PlanDigest(plan) };
        await plans.SaveAsync(lease, plan, cancellationToken);
        return new(plan, skipped.ToImmutable());
    }

    private static bool IsUnavailableStorageTarget(Exception error) => error is IOException or UnauthorizedAccessException ||
        error is ShouException { Code: "permission_denied" or "read_failed" or "io_error" or "not_found" or "coverage_incomplete" or
            "protected_location" or "protected_data" or "excluded" or "foreign_owner" or "unsupported_entry" or "multiple_links" or "active_target" or "activity_unknown" };

    private async Task<ImmutableArray<FileEntry>> ReadStorageManifestAsync(WindowsPath path, ScanBudget budget, CancellationToken token, Action<int>? observeEntries = null)
    {
        var entry = await storageFiles!.InspectAsync(path, token);
        if (entry.Kind == EntryKind.File) { observeEntries?.Invoke(1); return [entry]; }
        if (entry.Kind != EntryKind.Directory) throw Stale();
        var scan = await scanner.ScanAsync(path, budget, null, token);
        observeEntries?.Invoke(scan.Entries.Length);
        token.ThrowIfCancellationRequested();
        if (scan.RootIdentity != entry.Identity) throw Stale();
        if (!scan.IsComplete || !scan.IsCompleteAt(path))
        {
            if (scan.Issues.Any(issue => issue.Code is "entry_limit" or "time_limit"))
                throw new ShouException("resource_limit", "Storage review reached its shared budget.");
            if (scan.Issues.Any(issue => issue.Code is "directory_changed" or "entry_changed" or "invalid_directory_entry")) throw Stale();
            throw new ShouException("coverage_incomplete", "This folder was not completely scanned.");
        }
        return scan.Entries.Select(value => value.Entry).OrderBy(value => value.Path.Value, StringComparer.Ordinal).ToImmutableArray();
    }

    private async Task VerifyStorageItemsAsync(Configuration configuration, CleanupPlanSource source, IEnumerable<CleanupPlanItem> items, ValidationBudget budget, CancellationToken token)
    {
        if (storageFiles is null) throw new ShouException("unsupported_capability", "Native storage inspection is unavailable.");
        foreach (var item in items)
        {
            foreach (var expected in item.Context)
                if (!FileManifestVerification.MatchesEntry(await storageFiles.InspectAsync(expected.Path, token), expected, allowingDirectoryChanges: true)) throw Stale();
            var manifest = await ReadStorageManifestAsync(item.Path, budget.NextScan(), token);
            budget.ObserveEntries(manifest.Length);
            if (!manifest.SequenceEqual(item.Manifest)) throw Stale();
            RequireStoragePolicy(configuration, source.Workspace, manifest);
            await RequireIdleAsync(source.Workspace, item, token);
        }
    }

    private void RequireStoragePolicy(Configuration configuration, Workspace workspace, ImmutableArray<FileEntry> manifest)
    {
        var target = manifest[0].Path;
        if (target.IsVolumeRoot || protection.HomeDirectory.IsWithin(target) || target.IsWithin(protection.DataDirectory) || protection.DataDirectory.IsWithin(target) ||
            protection.SystemDirectories.Any(path => target.IsWithin(path) || path.IsWithin(target))) throw new ShouException("protected_location", "The selection contains a protected location.");
        var identities = new HashSet<FileIdentity>();
        foreach (var entry in manifest)
        {
            if (entry.Identity.OwnerSid != protection.OwnerSid) throw new ShouException("foreign_owner", "Some files belong to another user.");
            if (entry.Kind is not (EntryKind.Directory or EntryKind.File)) throw new ShouException("unsupported_entry", "This folder contains links or unsupported entries.");
            if (entry.Kind == EntryKind.File && entry.LinkCount != 1) throw new ShouException("multiple_links", "This folder contains files with multiple hard links.");
            if (entry.Identity.VolumeSerialNumber != workspace.Identity.VolumeSerialNumber || !identities.Add(entry.Identity)) throw Stale();
            for (var path = entry.Path; path is not null; path = path.Parent)
                if (StorageProtectedNames.Contains(path.Name) || path.Name.StartsWith(".env.", StringComparison.OrdinalIgnoreCase))
                    throw new ShouException("protected_data", "The selection contains credentials or protected storage.");
            for (var path = entry.Path; path is not null && path.IsWithin(workspace.Path, includeRoot: false); path = path.Parent)
                if (configuration.GlobalExclusions.Any(pattern => new RulePattern(pattern).Matches(path.RelativeTo(workspace.Path, caseSensitive: true))))
                    throw new ShouException("excluded", "The selection contains excluded content.");
            foreach (var registered in configuration.Workspaces.Where(value => entry.Path.IsWithin(value.Path, includeRoot: false)))
                for (var path = entry.Path; path is not null && path.IsWithin(registered.Path, includeRoot: false); path = path.Parent)
                    if (registered.Exclusions.Concat(configuration.GlobalExclusions).Any(pattern => new RulePattern(pattern).Matches(path.RelativeTo(registered.Path, caseSensitive: true))))
                        throw new ShouException("excluded", "The selection contains excluded content.");
        }
    }
    private static readonly HashSet<string> StorageProtectedNames = new(StringComparer.OrdinalIgnoreCase)
    { ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".env", ".git-credentials", ".password-store", "OneDrive", "Dropbox", "iCloudDrive", "Windows", "Program Files", "Program Files (x86)", "ProgramData", "$Recycle.Bin", "System Volume Information" };
}
