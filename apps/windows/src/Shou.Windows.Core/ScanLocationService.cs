using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;

namespace Shou.Windows.Core;

public sealed record DiscoveredLocation(string Id, string Title, WindowsPath Path, string Category, string Origin,
    string? WorkspaceId, string State, string? Issue, FileIdentity? Identity = null, bool CaseSensitive = false);
public sealed record LocationDiscovery(string ConfigurationRevision, ImmutableArray<DiscoveredLocation> Locations);
public sealed record LocationPreparation(ImmutableArray<Workspace> Workspaces, ImmutableArray<ScanIssue> Issues);
public sealed record SystemScan(ImmutableArray<CleanupScan> Scans, ImmutableArray<ScanIssue> Issues, string State);

/// <summary>Conventional roots are bounded discovery hints. Explicit registrations and exclusions take precedence.</summary>
public sealed class ScanLocationService(ConfigurationService configuration, BuiltinRuleCatalog catalog, IWindowsFileSystem files,
    string ownerSid, TimeProvider? timeProvider = null)
{
    public static readonly TimeSpan DiscoveryDuration = TimeSpan.FromSeconds(10);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async Task<LocationDiscovery> DiscoverAsync(bool includeProjects = false, CancellationToken cancellationToken = default)
    {
        using var deadline = new CancellationTokenSource(DiscoveryDuration, clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var token = linked.Token;
        try
        {
            var saved = await configuration.ReadAsync(token);
            var results = ImmutableArray.CreateBuilder<DiscoveredLocation>();
            var identities = new HashSet<FileIdentity>();
            var accepted = new List<WindowsPath>();
            var candidates = saved.Workspaces.Where(workspace => includeProjects || catalog.Locations.Any(value => value.Path == workspace.Path))
                .Select(workspace => (Location: new BuiltinLocation(workspace.Id, "Scan Locations", "project", workspace.Path), Workspace: (Workspace?)workspace, Origin: "included"))
                .Concat(catalog.Locations.Select(location => (Location: location, Workspace: (Workspace?)null, Origin: "builtin")))
                .Concat(includeProjects ? catalog.ProjectPaths.Select(relative =>
                {
                    var path = catalog.Directories.Home.Append(relative);
                    var id = "project-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(path.Value)))[..20];
                    return (Location: new BuiltinLocation(id, "Developer Projects", "project", path), Workspace: (Workspace?)null, Origin: "automatic");
                }) : []);
            foreach (var (location, workspace, origin) in candidates)
            {
                token.ThrowIfCancellationRequested();
                if (workspace is null && (saved.Workspaces.Any(value => Overlap(value.Path, location.Path)) || accepted.Any(path => Overlap(path, location.Path)))) continue;
                try
                {
                    var entry = await files.InspectAsync(location.Path, token).AsTask().WaitAsync(token);
                    if (entry.Path != location.Path || entry.Kind != EntryKind.Directory || entry.Identity.OwnerSid != ownerSid)
                        throw new ShouException("permission_denied", "The location is not a verified current-user-owned directory.");
                    if (workspace is not null && (entry.Identity != workspace.Identity || entry.IsCaseSensitive != workspace.CaseSensitive))
                        throw new ShouException("source_changed", "The registered location changed identity.");
                    if (!identities.Add(entry.Identity)) continue;
                    accepted.Add(location.Path);
                    results.Add(new(location.Id, location.Title, location.Path, location.Category, origin, workspace?.Id, "available", null, entry.Identity, entry.IsCaseSensitive));
                }
                catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
                {
                    var code = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "io_error";
                    results.Add(new(location.Id, location.Title, location.Path, location.Category, origin, workspace?.Id,
                        code == "not_found" ? "missing" : "unavailable", workspace is null && code == "not_found" ? null : code));
                }
            }
            return new(saved.Revision, results.ToImmutable());
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && deadline.IsCancellationRequested)
        { throw new ShouException("time_limit", "Scan-location discovery reached its time budget."); }
    }

    public async Task<LocationPreparation> PrepareAsync(bool includeProjects = false, CancellationToken cancellationToken = default)
    {
        var discovery = await DiscoverAsync(includeProjects, cancellationToken);
        var issues = discovery.Locations.Where(location => location.Issue is not null).Select(location => new ScanIssue(location.Path, location.Issue!)).ToImmutableArray();
        var proposed = discovery.Locations.Where(value => value.State == "available").Select(location =>
            new Workspace(location.WorkspaceId ?? RecordKey.New("ws"), location.Origin == "included" ? "existing" : "shou-location-" + location.Id,
                location.Path, location.Identity!, location.CaseSensitive, [], clock.GetUtcNow())).ToImmutableArray();
        var workspaces = await configuration.RegisterDiscoveredAsync(proposed, discovery.ConfigurationRevision, cancellationToken);
        return new(workspaces, issues);
    }

    public async Task<SystemScan> ScanAsync(CleanupScanService scans, bool includeProjects, ScanBudget budget, CancellationToken cancellationToken = default)
    {
        budget.Validate();
        var prepared = await PrepareAsync(includeProjects, cancellationToken);
        var current = await configuration.ReadAsync(cancellationToken);
        var result = await ScanWorkspacesAsync(scans, prepared.Workspaces, prepared.Issues, current.Revision, budget, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        return result;
    }

    /// <summary>Scans only the saved scope. Completed snapshots survive a cooperative stop; no locations are discovered or registered.</summary>
    public async Task<SystemScan> ScanRegisteredAsync(CleanupScanService scans, ImmutableArray<string> workspaceIds,
        ScanBudget budget, CancellationToken cancellationToken = default)
    {
        budget.Validate();
        cancellationToken.ThrowIfCancellationRequested();
        if (workspaceIds.IsDefaultOrEmpty || workspaceIds.Length > ConfigurationCodec.MaximumWorkspaces ||
            workspaceIds.Any(id => !RecordKey.IsId(id, "ws")) || workspaceIds.Distinct().Count() != workspaceIds.Length)
            throw new ShouException("invalid_argument", "Choose distinct registered scan locations.");
        var current = await configuration.ReadAsync(cancellationToken);
        var roots = workspaceIds.Select(id => current.Workspaces.FirstOrDefault(workspace => workspace.Id == id) ??
            throw new ShouException("plan_stale", "A selected scan location is no longer registered.")).ToImmutableArray();
        return await ScanWorkspacesAsync(scans, roots, [], current.Revision, budget, cancellationToken);
    }

    private async Task<SystemScan> ScanWorkspacesAsync(CleanupScanService scans, ImmutableArray<Workspace> workspaces,
        ImmutableArray<ScanIssue> initialIssues, string revision, ScanBudget budget, CancellationToken cancellationToken)
    {
        var issues = initialIssues.ToBuilder();
        var snapshots = ImmutableArray.CreateBuilder<CleanupScan>();
        var remaining = budget.MaxEntries;
        var started = clock.GetTimestamp();
        var cancelled = false;
        var stale = false;
        foreach (var workspace in workspaces)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                cancelled = true;
                issues.Add(new(workspace.Path, "cancelled"));
                continue;
            }
            if (stale) { issues.Add(new(workspace.Path, "plan_stale")); continue; }
            var duration = budget.Duration - clock.GetElapsedTime(started);
            if (remaining <= 0 || duration <= TimeSpan.Zero)
            {
                issues.Add(new(workspace.Path, remaining <= 0 ? "resource_limit" : "time_limit"));
                continue;
            }
            try
            {
                var result = await scans.ScanAsync(workspace.Id, budget with { MaxEntries = remaining, MaxDuration = duration }, cancellationToken);
                if (result.ConfigurationRevision != revision || !result.Workspace.SameRegistration(workspace))
                { stale = true; issues.Add(new(workspace.Path, "plan_stale")); continue; }
                snapshots.Add(result);
                remaining -= result.Scan.Entries.Length;
                issues.AddRange(result.Scan.Issues); issues.AddRange(result.AnalysisIssues);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            { cancelled = true; issues.Add(new(workspace.Path, "cancelled")); }
            catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
            {
                var code = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "io_error";
                issues.Add(new(workspace.Path, code));
                // A failed publication may have consumed the entire remaining scan allowance.
                remaining = 0;
                stale = code == "plan_stale";
            }
        }
        return new(snapshots.ToImmutable(), issues.Distinct().ToImmutableArray(), cancelled || cancellationToken.IsCancellationRequested ? "cancelled" :
            issues.Count == 0 && snapshots.All(value => value.Scan.IsComplete && value.AnalysisIssues.IsEmpty) ? "complete" : "partial");
    }

    private static bool Overlap(WindowsPath first, WindowsPath second) => first.IsWithin(second) || second.IsWithin(first);
}
