using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;

namespace Shou.Windows.Core;

public sealed record DiscoveredLocation(string Id, string Title, WindowsPath Path, string Category, string Origin,
    string? WorkspaceId, string State, string? Issue, FileIdentity? Identity = null, bool CaseSensitive = false);
public sealed record LocationDiscovery(string ConfigurationRevision, ImmutableArray<DiscoveredLocation> Locations);
public sealed record LocationPreparation(ImmutableArray<Workspace> Workspaces, ImmutableArray<ScanIssue> Issues);
public enum CleanupScanMode { Standard, Folders, Volumes }
public sealed record CleanupScanScope(CleanupScanMode Mode, ImmutableArray<WindowsPath> Paths)
{
    public static CleanupScanScope Standard { get; } = new(CleanupScanMode.Standard, []);
}
public interface ICleanupScanVolumes
{
    Task<ImmutableArray<WindowsPath>> ReadAsync(CancellationToken cancellationToken);
}
public sealed record SystemScan(ImmutableArray<CleanupScan> Scans, ImmutableArray<ScanIssue> Issues, string State);

/// <summary>Conventional roots are bounded discovery hints. Explicit registrations and exclusions take precedence.</summary>
public sealed class ScanLocationService(ConfigurationService configuration, BuiltinRuleCatalog catalog, IWindowsFileSystem files,
    string ownerSid, TimeProvider? timeProvider = null, ICleanupScanVolumes? volumes = null)
{
    public static readonly TimeSpan DiscoveryDuration = TimeSpan.FromSeconds(10);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async Task<LocationDiscovery> DiscoverAsync(bool includeProjects = false, CancellationToken cancellationToken = default, CleanupScanScope? scope = null)
    {
        using var diagnostic = OperationDiagnostics.Start("locations.discover");
        using var deadline = new CancellationTokenSource(DiscoveryDuration, clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var token = linked.Token;
        try
        {
            var saved = await configuration.ReadAsync(token);
            var results = ImmutableArray.CreateBuilder<DiscoveredLocation>();
            var identities = new HashSet<FileIdentity>();
            var accepted = new List<WindowsPath>();
            scope ??= CleanupScanScope.Standard;
            if (!Enum.IsDefined(scope.Mode) || scope.Paths.IsDefault || scope.Paths.Length > 256 ||
                scope.Mode == CleanupScanMode.Folders && scope.Paths.IsEmpty)
                throw new ShouException("invalid_argument", "Choose between one and 256 scan folders.");
            var listingCount = 0;
            async Task<ImmutableArray<WindowsPath>> Children(WindowsPath parent)
            {
                var children = ImmutableArray.CreateBuilder<WindowsPath>();
                if (++listingCount > 128) { Gap(parent, "resource_limit"); return []; }
                try
                {
                    var count = 0;
                    await foreach (var item in files.ReadDirectoryAsync(parent, token).WithCancellation(token))
                    {
                        if (++count > 4096) { Gap(parent, "resource_limit"); break; }
                        if (item.Path.Parent?.SamePath(parent) != true) { Gap(parent, "source_changed"); continue; }
                        if (item.ErrorCode is not null) { Gap(item.Path, item.ErrorCode); continue; }
                        if (item.Entry is { Kind: EntryKind.Directory } entry && entry.Path.SamePath(item.Path) && !item.Path.Name.StartsWith('.'))
                            children.Add(item.Path);
                    }
                }
                catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
                { Gap(parent, error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "io_error"); }
                return children.Distinct().OrderBy(path => path.Value, StringComparer.Ordinal).ToImmutableArray();
            }
            void Gap(WindowsPath path, string issue) => results.Add(new(Project(path).Id + "-issue", "Scan Locations", path, "project", "automatic", null, "unavailable", issue));
            BuiltinLocation Project(WindowsPath path) => new("project-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(path.Value)))[..20], "Developer Projects", "project", path);
            var projectPaths = new List<WindowsPath>();
            var standard = scope.Mode != CleanupScanMode.Folders;
            if (standard && includeProjects)
                projectPaths.AddRange((await Children(catalog.Directories.Home)).Where(path =>
                    !catalog.Locations.Any(location => Overlap(location.Path, path)) && !path.Name.Equals("AppData", StringComparison.OrdinalIgnoreCase)));
            if (scope.Mode == CleanupScanMode.Folders) projectPaths.AddRange(scope.Paths);
            if (scope.Mode == CleanupScanMode.Volumes)
            {
                var available = volumes is null ? throw new ShouException("unsupported_capability", "Choose available local disks.") : await volumes.ReadAsync(token);
                if (scope.Paths.Any(path => !available.Any(value => value.SamePath(path))))
                    throw new ShouException("plan_stale", "A selected disk is no longer available.");
                foreach (var disk in scope.Paths.Distinct().Where(path => !catalog.Directories.Home.IsWithin(path)))
                    projectPaths.AddRange(await Children(disk));
            }
            var candidates = saved.Workspaces.Where(workspace => standard ? includeProjects || catalog.Locations.Any(value => value.Path == workspace.Path) :
                    scope.Paths.Any(path => workspace.Path.IsWithin(path)))
                .Select(workspace => (Location: new BuiltinLocation(workspace.Id, "Scan Locations", "project", workspace.Path), Workspace: (Workspace?)workspace, Origin: "included"))
                .Concat(standard ? catalog.Locations.Select(location => (Location: location, Workspace: (Workspace?)null, Origin: "builtin")) : [])
                .Concat(projectPaths.Select(path => (Location: Project(path), Workspace: (Workspace?)null, Origin: "automatic"))).ToList();
            for (var index = 0; index < candidates.Count; index++)
            {
                var (location, workspace, origin) = candidates[index];
                token.ThrowIfCancellationRequested();
                if (workspace is null)
                {
                    if (accepted.Any(path => location.Path.IsWithin(path))) continue;
                    if (saved.Workspaces.Any(value => location.Path.IsWithin(value.Path)))
                    { Gap(location.Path, "saved_scope_required"); continue; }
                    if (saved.Workspaces.Any(value => value.Path.IsWithin(location.Path)))
                    {
                        candidates.AddRange((await Children(location.Path)).Select(path => (Project(path), (Workspace?)null, "automatic")));
                        continue;
                    }
                }
                if (accepted.Count >= ConfigurationCodec.MaximumWorkspaces) { Gap(location.Path, "resource_limit"); break; }
                try
                {
                    var entry = await files.InspectAsync(location.Path, token).AsTask().WaitAsync(token);
                    diagnostic.Step("location_identity", location.Path, entry.Identity.OwnerSid == ownerSid ? "current_user" :
                        entry.Identity.OwnerSid == "S-1-5-18" ? "system" : entry.Identity.OwnerSid == "S-1-5-32-544" ? "administrators" : "other");
                    if (entry.Path != location.Path) throw new ShouException("source_changed", "The scan location changed path.");
                    await ScanLocationAccess.VerifyAsync(files, catalog, entry, ownerSid, token);
                    if (workspace is not null && (entry.Identity != workspace.Identity || entry.IsCaseSensitive != workspace.CaseSensitive))
                        throw new ShouException("source_changed", "The registered location changed identity.");
                    if (!identities.Add(entry.Identity)) continue;
                    accepted.Add(location.Path);
                    results.Add(new(location.Id, location.Title, location.Path, location.Category, origin, workspace?.Id, "available", null, entry.Identity, entry.IsCaseSensitive));
                }
                catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
                {
                    var code = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "io_error";
                    diagnostic.Issue(code, "location_inspect", location.Path);
                    results.Add(new(location.Id, location.Title, location.Path, location.Category, origin, workspace?.Id,
                        code == "not_found" ? "missing" : "unavailable", workspace is null && code == "not_found" ? null : code));
                }
            }
            diagnostic.Complete(count: results.Count, issueCount: results.Count(location => location.Issue is not null));
            return new(saved.Revision, results.ToImmutable());
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && deadline.IsCancellationRequested)
        {
            var error = new ShouException("time_limit", "Scan-location discovery reached its time budget.");
            diagnostic.Fail(error, "discovery_budget"); throw error;
        }
        catch (Exception error) { diagnostic.Fail(error, "discovery"); throw; }
    }

    public async Task<LocationPreparation> PrepareAsync(bool includeProjects = false, CancellationToken cancellationToken = default, CleanupScanScope? scope = null)
    {
        using var diagnostic = OperationDiagnostics.Start("locations.prepare");
        var stage = "discover";
        try
        {
            var discovery = await DiscoverAsync(includeProjects, cancellationToken, scope);
            var issues = discovery.Locations.Where(location => location.Issue is not null).Select(location => new ScanIssue(location.Path, location.Issue!)).ToImmutableArray();
            var proposed = discovery.Locations.Where(value => value.State == "available").Select(location =>
                new Workspace(location.WorkspaceId ?? RecordKey.New("ws"), location.Origin == "included" ? "existing" : "shou-location-" + location.Id,
                    location.Path, location.Identity!, location.CaseSensitive, [], clock.GetUtcNow())).ToImmutableArray();
            stage = "configuration_register";
            var workspaces = await configuration.RegisterDiscoveredAsync(proposed, discovery.ConfigurationRevision, cancellationToken);
            diagnostic.Complete(count: workspaces.Length, issueCount: issues.Length);
            return new(workspaces, issues);
        }
        catch (Exception error) { diagnostic.Fail(error, stage); throw; }
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
        using var diagnostic = OperationDiagnostics.Start("cleanup.scan_locations");
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
                if (!await configuration.IsAccessibleAsync(workspace, cancellationToken))
                { issues.Add(new(workspace.Path, "source_changed")); continue; }
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
                diagnostic.Issue(code, "workspace_scan_or_publish", workspace.Path);
                issues.Add(new(workspace.Path, code));
                // A failed publication may have consumed the entire remaining scan allowance.
                remaining = 0;
                stale = code == "plan_stale";
            }
        }
        var state = cancelled || cancellationToken.IsCancellationRequested ? "cancelled" :
            issues.Count == 0 && snapshots.All(value => value.Scan.IsScopeComplete && value.AnalysisIssues.IsEmpty) ? "complete" : "partial";
        foreach (var issue in issues.Distinct().Take(200)) diagnostic.Issue(issue.Code, "scan_coverage", issue.Path);
        diagnostic.Complete(state, snapshots.Sum(value => (long)value.Scan.Entries.Length), issues.Count);
        return new(snapshots.ToImmutable(), issues.Distinct().ToImmutableArray(), state);
    }

    private static bool Overlap(WindowsPath first, WindowsPath second) => first.IsWithin(second) || second.IsWithin(first);
}
