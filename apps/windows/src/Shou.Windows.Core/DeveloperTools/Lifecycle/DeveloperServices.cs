using System.Collections.Immutable;
using System.Text.Json;

namespace Shou.Windows.Core;

public sealed record DeveloperService(string Id, string ToolId, string Source, string Name, string Version, string InstallationPath,
    string ConfigurationPath, string State, bool RegisteredAtLogin, string Identity, string DefinitionIdentity, string? Issue, string? LogPath = null, string? ErrorLogPath = null, uint? ProcessId = null)
{
    public bool Controllable => Issue is null && State is "running" or "stopped";
}
public sealed record DeveloperServiceSnapshot(ImmutableArray<DeveloperService> Services, ImmutableArray<string> Issues);
public enum DeveloperServiceAction { Start, Stop, Restart }
public sealed record DeveloperServiceProgress(string ServiceId, string Stage);
public sealed record DeveloperServiceResult(string Id, DeveloperService Service, bool RequestedRunning, string State, DeveloperService? Observed, DeveloperServiceAction Action = DeveloperServiceAction.Start, string? FailureCode = null, string? Stage = null);
public interface IDeveloperServices
{
    Task<DeveloperServiceSnapshot> ScanAsync(DeveloperToolCatalog catalog, DeveloperToolInventory inventory, CancellationToken cancellationToken);
    Task<DeveloperService> InspectAsync(DeveloperService expected, CancellationToken cancellationToken);
    Task SetRunningAsync(bool running, DeveloperService expected, DateTimeOffset expiresAt, CancellationToken cancellationToken);
}
public sealed class DeveloperServiceController(DeveloperToolCatalog catalog, IDeveloperServices platform, Func<IRecordStore> makeStore)
{
    private readonly SemaphoreSlim operation = new(1, 1);
    private readonly Dictionary<string, DeveloperService> observations = new(StringComparer.Ordinal);
    public async Task<DeveloperServiceSnapshot> ScanAsync(DeveloperToolInventory inventory, CancellationToken cancellationToken = default, string? toolId = null, IReadOnlySet<string>? toolIds = null)
    {
        await operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (toolId is not null && toolIds is not null) throw Changed();
            var selected = toolId is not null ? catalog.Tools.Where(t => t.Id == toolId).ToImmutableArray() : toolIds is not null ? catalog.Tools.Where(t => toolIds.Contains(t.Id)).ToImmutableArray() : catalog.Tools;
            if (selected.IsEmpty) throw Changed();
            if (toolId is null && toolIds is null) observations.Clear();
            else foreach (var id in observations.Where(p => selected.Any(t => t.Id == p.Value.ToolId)).Select(p => p.Key).ToArray()) observations.Remove(id);
            var snapshot = await platform.ScanAsync(catalog with { Tools = selected }, inventory, cancellationToken).ConfigureAwait(false);
            if (snapshot.Services.IsDefault || snapshot.Services.Length > 512 || snapshot.Services.Select(r => r.Id).Distinct(StringComparer.Ordinal).Count() != snapshot.Services.Length ||
                snapshot.Services.Any(r => r.Identity.Length == 0 || !selected.Any(t => t.Id == r.ToolId))) throw Changed();
            foreach (var row in snapshot.Services) observations[row.Id] = row;
            return snapshot;
        }
        finally { operation.Release(); }
    }
    public Task<DeveloperServiceResult> SetRunningAsync(bool running, DeveloperService expected, CancellationToken cancellationToken = default) => PerformAsync(running ? DeveloperServiceAction.Start : DeveloperServiceAction.Stop, expected, cancellationToken);
    public async Task<DeveloperServiceResult> PerformAsync(DeveloperServiceAction action, DeveloperService expected, CancellationToken cancellationToken = default, IProgress<DeveloperServiceProgress>? progress = null)
    {
        if (!Enum.IsDefined(action)) throw Changed();
        var running = action != DeveloperServiceAction.Stop;
        await operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!observations.Remove(expected.Id, out var saved) || saved != expected || !expected.Controllable || (action == DeveloperServiceAction.Restart ? expected.State != "running" : running == (expected.State == "running"))) throw Changed();
            var expiresAt = DateTimeOffset.UtcNow.AddMinutes(2);
            await using var lease = await makeStore().AcquireLeaseAsync(cancellationToken).ConfigureAwait(false);
            if (await platform.InspectAsync(expected, cancellationToken).ConfigureAwait(false) != expected) throw Changed();
            var id = Guid.NewGuid().ToString("N");
            var intent = new DeveloperServiceResult(id, expected, running, "requested", null, action);
            await lease.WriteAsync("developer_service_intent_" + id, JsonSerializer.SerializeToUtf8Bytes(intent), cancellationToken).ConfigureAwait(false);
            DeveloperServiceResult result; var dispatched = false; var stage = "checking";
            void Report(string value) { stage = value; progress?.Report(new(expected.Id, value)); }
            try
            {
                cancellationToken.ThrowIfCancellationRequested(); dispatched = true;
                var current = expected;
                if (action == DeveloperServiceAction.Restart)
                {
                    Report("stopping");
                    await platform.SetRunningAsync(false, current, expiresAt, cancellationToken).ConfigureAwait(false);
                    using var stopVerification = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                    var afterStop = await platform.InspectAsync(current, stopVerification.Token).ConfigureAwait(false);
                    if (!SameDefinition(afterStop, expected) || !afterStop.Controllable || afterStop.State != "stopped") throw Changed();
                    current = afterStop;
                    await lease.WriteAsync("developer_service_stage_" + id, JsonSerializer.SerializeToUtf8Bytes(new DeveloperServiceResult(id, expected, running, "stopped", afterStop, action)), CancellationToken.None).ConfigureAwait(false);
                    Report("stopped");
                    cancellationToken.ThrowIfCancellationRequested();
                    if (DateTimeOffset.UtcNow >= expiresAt) throw Changed();
                }
                Report(running ? "starting" : "stopping");
                await platform.SetRunningAsync(running, current, expiresAt, cancellationToken).ConfigureAwait(false);
                Report("verifying");
                using var verification = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                var after = await platform.InspectAsync(expected, verification.Token).ConfigureAwait(false);
                var verified = after.Issue is null && after.State == (running ? "running" : "stopped") && SameDefinition(after, expected);
                result = new(id, expected, running, verified ? "succeeded" : "unknown", after, action, verified ? null : "developer_service_verification_failed", verified ? null : stage);
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            {
                DeveloperService? after = null;
                try { using var verification = new CancellationTokenSource(TimeSpan.FromSeconds(30)); after = await platform.InspectAsync(expected, verification.Token).ConfigureAwait(false); }
                catch (Exception observationError) when (observationError is not OutOfMemoryException) { }
                var partial = action == DeveloperServiceAction.Restart && after is { Controllable: true, State: "stopped" } && SameDefinition(after, expected);
                result = new(id, expected, running, partial ? "partial" : dispatched ? "unknown" : "not_started", after, action, (error as ShouException)?.Code ?? "developer_service_unavailable", stage);
            }
            await lease.WriteAsync("developer_service_result_" + id, JsonSerializer.SerializeToUtf8Bytes(result), CancellationToken.None).ConfigureAwait(false);
            if (result.State == "succeeded" && result.Observed is { } observed) observations[observed.Id] = observed;
            return result;
        }
        finally { operation.Release(); }
    }
    private static bool SameDefinition(DeveloperService row, DeveloperService expected) => row.Id == expected.Id && row.ToolId == expected.ToolId && row.Source == expected.Source && row.Name == expected.Name && row.Version == expected.Version &&
        row.InstallationPath == expected.InstallationPath && row.ConfigurationPath == expected.ConfigurationPath && row.DefinitionIdentity == expected.DefinitionIdentity && row.RegisteredAtLogin == expected.RegisteredAtLogin && row.LogPath == expected.LogPath && row.ErrorLogPath == expected.ErrorLogPath;
    private static ShouException Changed() => new("developer_service_changed", "Refresh the exact service source and state before trying again.");
}
