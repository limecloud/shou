using System.Collections.Immutable;
using System.Text.Json;

namespace Shou.Windows.Core;

/// <summary>Read-only browser inspection; saving a scan never grants record-deletion authority.</summary>
public sealed class PrivacyScanService(IRecordStore store, RuleSchemaValidator validator, WindowsPrivacySourcePolicy policy,
    IWindowsFileSystem files, IPrivacyDatabaseInspection databases, IPrivacyBrowserActivity activity, string ownerSid,
    WindowsPath home, WindowsPath dataDirectory, TimeProvider? timeProvider = null)
{
    public const int MaximumScanBytes = 16_777_216;
    public static readonly TimeSpan ScanLifetime = TimeSpan.FromMinutes(15);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly ConfigurationCodec configurationCodec = new(validator);

    public async Task<PrivacyScan> ScanAsync(PrivacyTimeRange range = PrivacyTimeRange.LastHour, CancellationToken cancellationToken = default)
    {
        var now = clock.GetUtcNow();
        var window = PrivacyWindow.Create(range, now);
        var configuration = configurationCodec.Decode(await store.ReadAsync("configuration", ConfigurationCodec.MaximumBytes, cancellationToken));
        var configurationDigest = configurationCodec.Digest(configuration);
        using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(2), clock);
        using var stopped = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var token = stopped.Token;
        PrivacyDiscovery discovery;
        try { discovery = await new PrivacySourceDiscovery(policy, files, ownerSid, clock).DiscoverAsync(token); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { discovery = new([], [new(null, "time_limit")], false); }
        var sources = ImmutableArray.CreateBuilder<PrivacySourceObservation>();
        var issues = discovery.Issues.ToBuilder();
        foreach (var source in discovery.Sources)
        {
            try
            {
                token.ThrowIfCancellationRequested();
                RequireAllowed(source, configuration);
                var before = await activity.InspectAsync(source.Browser, token);
                if (before.State != ActivityState.Idle)
                { sources.Add(Unavailable(source, before.State == ActivityState.Active ? PrivacySourceState.BrowserRunning : PrivacySourceState.ActivityUnknown, "privacy_browser_not_idle")); continue; }
                var observation = await databases.InspectAsync(source, window, token);
                ValidateObservation(source, observation);
                if ((await activity.InspectAsync(source.Browser, token)).State != ActivityState.Idle)
                { sources.Add(Unavailable(source, PrivacySourceState.ActivityUnknown, "privacy_browser_not_idle")); continue; }
                sources.Add(new(source, observation.RecordCount == 0 ? PrivacySourceState.Empty : PrivacySourceState.Ready,
                    observation.RecordCount, null, observation.SchemaDigest, observation.Evidence));
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            { sources.Add(Unavailable(source, PrivacySourceState.Unavailable, "time_limit")); issues.Add(new(source.Browser, "time_limit")); break; }
            catch (ShouException error)
            {
                var state = error.Code switch
                {
                    "privacy_excluded" => PrivacySourceState.Excluded, "permission_denied" => PrivacySourceState.PermissionRequired,
                    "privacy_schema_unsupported" => PrivacySourceState.SchemaUnsupported, _ => PrivacySourceState.Unavailable
                };
                sources.Add(Unavailable(source, state, ErrorCode(error)));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            { sources.Add(Unavailable(source, error is UnauthorizedAccessException ? PrivacySourceState.PermissionRequired : PrivacySourceState.Unavailable,
                error is UnauthorizedAccessException ? "permission_denied" : "read_failed")); }
        }
        cancellationToken.ThrowIfCancellationRequested();
        if (deadline.IsCancellationRequested && !issues.Any(issue => issue.Code == "time_limit")) issues.Add(new(null, "time_limit"));
        var result = new PrivacyScan(1, RecordKey.New("privacy_scan"), now, now + ScanLifetime, window, configurationDigest,
            sources.ToImmutable(), issues.Distinct().ToImmutableArray(), discovery.Complete && sources.Count == discovery.Sources.Length &&
                sources.All(source => source.State is PrivacySourceState.Ready or PrivacySourceState.Empty) && issues.Count == 0, "");
        result = result with { Digest = RecordJson.Digest(result with { Digest = "" }) };
        ValidateScan(result);
        await using var lease = await store.AcquireLeaseAsync(cancellationToken);
        if (configurationCodec.Digest(configurationCodec.Decode(await lease.ReadAsync("configuration", ConfigurationCodec.MaximumBytes, cancellationToken))) != configurationDigest)
            throw new ShouException("plan_stale", "Privacy protection settings changed. Scan again.");
        if (clock.GetUtcNow() < now || clock.GetUtcNow() >= result.ExpiresAt) throw new ShouException("plan_stale", "The privacy scan expired before publication.");
        if (await lease.ReadAsync(result.Id, MaximumScanBytes, cancellationToken) is not null) throw new ShouException("version_conflict", "The privacy scan already exists.");
        await lease.WriteAsync(result.Id, RecordJson.Encode(result, MaximumScanBytes), cancellationToken);
        return result;
    }

    public async Task<PrivacyScan> ReadAsync(string id, CancellationToken cancellationToken = default)
    {
        if (!RecordKey.IsId(id, "privacy_scan")) throw new ShouException("invalid_argument", "Choose a valid privacy scan identifier.");
        var bytes = await store.ReadAsync(id, MaximumScanBytes, cancellationToken) ?? throw new ShouException("not_found", "The privacy scan does not exist.");
        return Decode(bytes, id);
    }

    internal PrivacyScan Decode(byte[] bytes, string id)
    {
        try
        {
            var result = JsonSerializer.Deserialize<PrivacyScan>(bytes, ContractJson.Options) ?? throw Corrupt();
            if (result.Id != id || bytes.Length > MaximumScanBytes) throw Corrupt();
            ValidateScan(result);
            return result;
        }
        catch (Exception error) when (error is JsonException or ArgumentException or InvalidOperationException or NullReferenceException or OverflowException or ShouException)
        { throw Corrupt(); }
    }

    internal void RequireAllowed(PrivacySourceDefinition source, Configuration configuration)
    {
        var root = policy.Validate(source);
        if (source.Path.IsWithin(dataDirectory) || dataDirectory.IsWithin(source.Path)) throw new ShouException("privacy_excluded", "Shou data is protected.");
        foreach (var suffix in new[] { "", "-wal", "-shm", "-journal" })
        {
            var path = WindowsPath.Parse(source.Path.Value + suffix);
            var relatives = new[] { path.RelativeTo(root.Anchor) }.Concat(path.IsWithin(home, includeRoot: false) ? [path.RelativeTo(home)] : Array.Empty<string>());
            foreach (var relative in relatives)
                if (Excluded(relative, configuration.GlobalExclusions)) throw new ShouException("privacy_excluded", "The privacy source matches an exclusion.");
            foreach (var workspace in configuration.Workspaces.Where(workspace => path.IsWithin(workspace.Path, includeRoot: false)))
                if (Excluded(path.RelativeTo(workspace.Path), workspace.Exclusions)) throw new ShouException("privacy_excluded", "The privacy source matches a workspace exclusion.");
        }
    }

    private static bool Excluded(string relative, ImmutableArray<string> patterns)
    {
        var parts = relative.Split('/');
        return patterns.Select(pattern => new RulePattern(pattern)).Any(pattern => Enumerable.Range(1, parts.Length)
            .Any(count => pattern.Matches(string.Join('/', parts.Take(count)))));
    }

    internal void ValidateObservation(PrivacySourceDefinition source, PrivacyDatabaseObservation observation)
    {
        var root = policy.Validate(source);
        var directories = new HashSet<WindowsPath> { root.Anchor };
        var directory = root.Anchor;
        foreach (var part in source.Path.Parent!.RelativeTo(root.Anchor, caseSensitive: true).Split('/'))
        { directory = directory.Append(part); directories.Add(directory); }
        if (observation is null || observation.RecordCount < 0 || !RecordJson.IsDigest(observation.SchemaDigest) || observation.Evidence.IsDefaultOrEmpty ||
            observation.Evidence.Length > 32 || observation.Evidence.Any(item => item?.Entry is null || !RecordJson.IsDigest(item.SecurityDigest)) ||
            observation.Evidence.Select(item => item.Entry.Path).Distinct().Count() != observation.Evidence.Length ||
            observation.Evidence.Count(item => item.Entry.Path == source.Path && item.Entry.Kind == EntryKind.File) != 1 ||
            !observation.Evidence.Where(item => item.Entry.Kind == EntryKind.Directory).Select(item => item.Entry.Path).ToHashSet().SetEquals(directories) ||
            observation.Evidence.Select(item => item.Entry.Identity).Distinct().Count() != observation.Evidence.Length) throw Corrupt();
        foreach (var item in observation.Evidence)
        {
            var entry = item.Entry;
            if (entry.Identity?.OwnerSid != ownerSid || entry.Identity.VolumeSerialNumber != observation.Evidence[0].Entry.Identity.VolumeSerialNumber ||
                entry.Kind is not (EntryKind.File or EntryKind.Directory) || entry.LogicalBytes < 0 || entry.AllocatedBytes < 0 ||
                entry.LastWriteUtc.Offset != TimeSpan.Zero || entry.ChangeUtc.Offset != TimeSpan.Zero || entry.Kind == EntryKind.File && entry.LinkCount != 1 ||
                entry.Kind == EntryKind.File && entry.Path != source.Path && entry.Path.Value != source.Path.Value + "-wal" ||
                entry.Kind == EntryKind.File && entry.Path != source.Path && entry.LogicalBytes <= 32 ||
                entry.Kind == EntryKind.Directory && (entry.LogicalBytes != 0 || entry.AllocatedBytes != 0 ||
                    entry.LastWriteUtc != DateTimeOffset.UnixEpoch || entry.ChangeUtc != DateTimeOffset.UnixEpoch)) throw Corrupt();
        }
    }

    private void ValidateScan(PrivacyScan scan)
    {
        if (scan.Version != 1 || !RecordKey.IsId(scan.Id, "privacy_scan") || scan.CreatedAt.Offset != TimeSpan.Zero || scan.ExpiresAt.Offset != TimeSpan.Zero ||
            scan.ExpiresAt - scan.CreatedAt != ScanLifetime || scan.Window is null || scan.Window.End != scan.CreatedAt ||
            !RecordJson.IsDigest(scan.ConfigurationDigest) || !RecordJson.IsDigest(scan.Digest) || scan.Sources.IsDefault ||
            scan.Sources.Length > PrivacySourceDiscovery.MaximumSources || scan.Issues.IsDefault || scan.Issues.Length > PrivacySourceDiscovery.MaximumEntries ||
            scan.Sources.Any(source => source?.Source is null || !Enum.IsDefined(source.State)) ||
            scan.Sources.Select(source => source.Source.Id).Distinct().Count() != scan.Sources.Length ||
            scan.Issues.Any(issue => issue is null || issue.Browser is { } browser && !Enum.IsDefined(browser) || !SafeCode(issue.Code))) throw Corrupt();
        scan.Window.Validate();
        foreach (var source in scan.Sources)
        {
            _ = policy.Validate(source.Source);
            if (source.State is PrivacySourceState.Ready or PrivacySourceState.Empty)
            {
                if (source.RecordCount is null || source.State == PrivacySourceState.Ready && source.RecordCount == 0 ||
                    source.State == PrivacySourceState.Empty && source.RecordCount != 0 || source.Reason is not null) throw Corrupt();
                ValidateObservation(source.Source, new(source.RecordCount.Value, source.SchemaDigest!, source.Evidence));
            }
            else if (source.RecordCount is not null || source.SchemaDigest is not null || !source.Evidence.IsEmpty || !SafeCode(source.Reason)) throw Corrupt();
        }
        if (scan.Complete && (!scan.Issues.IsEmpty || scan.Sources.Any(source => source.State is not (PrivacySourceState.Ready or PrivacySourceState.Empty)))) throw Corrupt();
        if (scan.Digest != RecordJson.Digest(scan with { Digest = "" })) throw Corrupt();
    }
    private static PrivacySourceObservation Unavailable(PrivacySourceDefinition source, PrivacySourceState state, string reason) => new(source, state, null, reason, null, []);
    private static bool SafeCode(string? code) => code is { Length: >= 1 and <= 80 } && code.All(character => char.IsAsciiLetterLower(character) || character == '_');
    private static string ErrorCode(ShouException error) => error.Code is "privacy_excluded" or "permission_denied" or "privacy_schema_unsupported" or
        "privacy_database_busy" or "privacy_query_limit" or "privacy_identity_unavailable" or "source_changed" or "privacy_database_unavailable" ? error.Code : "read_failed";
    private static ShouException Corrupt() => new("store_corrupt", "The privacy scan metadata is invalid or unsupported.");
}
