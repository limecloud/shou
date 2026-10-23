using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;

namespace Shou.Windows.Core;

public enum StartupSource { CurrentUserRun, CurrentUserRunOnce, MachineRun64, MachineRun32, MachineRunOnce64, MachineRunOnce32, CurrentUserStartup, CommonStartup, ScheduledTasks, PackagedStartupTasks }
public enum StartupSourceState { Complete, Missing, Partial, Unavailable, NotRead }
public enum ScheduledTaskState { Unknown, Disabled, Queued, Ready, Running }
public sealed record ScheduledTaskStatus(bool Enabled, ScheduledTaskState State);

public sealed record StartupDiscoveryBudget(int MaxEntries = 2000, TimeSpan? MaxDuration = null)
{
    public TimeSpan Duration => MaxDuration ?? TimeSpan.FromSeconds(5);
    public void Validate()
    {
        if (MaxEntries is < 1 or > 10_000 || Duration <= TimeSpan.Zero || Duration > TimeSpan.FromMinutes(1))
            throw new ShouException("invalid_argument", "Choose a startup discovery budget within 10,000 entries and 60 seconds.");
    }
}

// Arguments and environment values never cross the platform boundary.
public sealed record StartupRegistration(StartupSource Source, string RegistrationKey, string Name,
    string? ExecutablePath = null, string? DefinitionPath = null, ImmutableArray<string> Issues = default,
    ScheduledTaskStatus? ScheduledTask = null);
public sealed record StartupSourceCoverage(StartupSource Source, StartupSourceState State, int? InspectedEntries, ImmutableArray<string> Issues);
public sealed record StartupInventory(ImmutableArray<StartupRegistration> Registrations, ImmutableArray<StartupSourceCoverage> Sources);
public interface IStartupInventory
{
    Task<StartupInventory> ReadAsync(StartupDiscoveryBudget budget, CancellationToken cancellationToken);
}

public sealed record StartupItem(string Id, StartupSource Source, string RegistrationKey, string Name,
    WindowsPath? ExecutablePath, WindowsPath? DefinitionPath, ImmutableArray<string> Issues,
    ScheduledTaskStatus? ScheduledTask = null)
{
    public string Enablement => "unknown";
    public string RunningState => "not_observed";
    public bool? IsOrphan => null;
    public bool ControlAvailable => false;
}
public sealed record StartupSnapshot(string Id, DateTimeOffset ObservedAt, ScanState State,
    ImmutableArray<StartupItem> Items, ImmutableArray<StartupSourceCoverage> Sources, ImmutableArray<string> Limitations);
public sealed record StartupQuery(string Search = "", StartupSource? Source = null, int Offset = 0, int Limit = 100)
{
    public void Validate()
    {
        if (Search is null || Search.Length > 256 || Search.Length > 0 && !StartupInventoryService.DisplayText(Search, 256) ||
            Source is { } source && !Enum.IsDefined(source) || Offset is < 0 or > 10_000 || Limit is < 1 or > 500)
            throw new ShouException("invalid_argument", "Choose a printable search up to 256 characters, a known startup source and a page of 1 to 500 items.");
    }
}
public sealed record StartupPage(string SnapshotId, DateTimeOffset ObservedAt, ScanState State, int Total, int Offset,
    ImmutableArray<StartupItem> Items, bool HasNext, ImmutableArray<StartupSourceCoverage> Sources, ImmutableArray<string> Limitations);

public sealed class StartupInventoryService(IStartupInventory inventory, TimeProvider? timeProvider = null)
{
    public async Task<StartupSnapshot> ReadAsync(StartupDiscoveryBudget? budget = null, CancellationToken cancellationToken = default)
    {
        budget ??= new();
        budget.Validate();
        cancellationToken.ThrowIfCancellationRequested();
        var observed = (timeProvider ?? TimeProvider.System).GetUtcNow();
        var raw = await inventory.ReadAsync(budget, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        if (raw.Registrations.IsDefault || raw.Sources.IsDefault || raw.Registrations.Length > budget.MaxEntries ||
            raw.Sources.Length != Enum.GetValues<StartupSource>().Length || raw.Sources.Select(value => value.Source).Distinct().Count() != raw.Sources.Length ||
            raw.Sources.Any(value => !Enum.IsDefined(value.Source) || !Enum.IsDefined(value.State) || value.InspectedEntries < 0 ||
                (value.State is StartupSourceState.Complete or StartupSourceState.Missing) && value.InspectedEntries is null ||
                value.State == StartupSourceState.Missing && value.InspectedEntries != 0 || !ValidIssues(value.Issues)) ||
            raw.Sources.Sum(value => (long?)value.InspectedEntries) > budget.MaxEntries)
            throw InvalidInventory();
        var coverage = raw.Sources.ToDictionary(value => value.Source);
        foreach (var group in raw.Registrations.GroupBy(value => value.Source))
            if (!coverage.TryGetValue(group.Key, out var source) || source.InspectedEntries is not { } count || count < group.Count() ||
                source.State is StartupSourceState.Missing or StartupSourceState.NotRead)
                throw InvalidInventory();
        var items = ImmutableArray.CreateBuilder<StartupItem>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var registration in raw.Registrations)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!DisplayText(registration.RegistrationKey, 32760) || !DisplayText(registration.Name, 512) ||
                !registration.Issues.IsDefault && !ValidIssues(registration.Issues) ||
                registration.ScheduledTask is { } status && (registration.Source != StartupSource.ScheduledTasks || !Enum.IsDefined(status.State)))
            { Partial(registration.Source, "invalid_registration_metadata"); continue; }
            var id = RegistrationId(registration.Source, registration.RegistrationKey);
            if (!ids.Add(id)) { Partial(registration.Source, "duplicate_registration"); continue; }
            var issues = registration.Issues.IsDefault ? ImmutableArray<string>.Empty : registration.Issues;
            WindowsPath? PathValue(string? path)
            {
                if (path is null) return null;
                try
                {
                    if (!DisplayText(path, 32760) || path.Contains('%')) throw new ShouException("invalid_path", "Unresolved startup path.");
                    return WindowsPath.Parse(path);
                }
                catch (ShouException) { if (!issues.Contains("unresolved_path")) issues = issues.Add("unresolved_path"); return null; }
            }
            var executable = PathValue(registration.ExecutablePath);
            var definition = PathValue(registration.DefinitionPath);
            items.Add(new(id, registration.Source, registration.RegistrationKey, registration.Name, executable, definition, issues, registration.ScheduledTask));
        }
        var sources = coverage.Values.OrderBy(value => value.Source).ToImmutableArray();
        return new("startup_" + Guid.NewGuid().ToString("N"), observed,
            sources.All(value => (value.State is StartupSourceState.Complete or StartupSourceState.Missing) && value.Issues.IsEmpty) ? ScanState.Complete : ScanState.Partial,
            items.ToImmutable(), sources, ["fixed_registration_sources_only", "scheduled_boot_logon_tasks_visible_to_current_user_only", "scheduled_task_snapshot_not_atomic", "scheduled_task_state_is_not_startup_activation_or_process_state", "packaged_startup_declarations_only", "packaged_startup_activation_not_observed",
                "other_users_not_enumerated", "shortcut_targets_not_resolved", "effective_state_unknown", "process_state_not_observed", "controls_unavailable"]);

        void Partial(StartupSource source, string issue)
        {
            var current = coverage[source];
            coverage[source] = current with { State = StartupSourceState.Partial, Issues = current.Issues.Contains(issue) ? current.Issues : current.Issues.Add(issue) };
        }
    }

    public static StartupPage Page(StartupSnapshot snapshot, StartupQuery? query = null)
    {
        query ??= new();
        query.Validate();
        var matching = snapshot.Items.Where(item => (query.Source is null || item.Source == query.Source) &&
            new[] { item.Name, item.RegistrationKey, item.ExecutablePath?.Value, item.DefinitionPath?.Value }
                .Any(value => value?.Contains(query.Search, StringComparison.OrdinalIgnoreCase) == true))
            .OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase).ThenBy(item => item.Id, StringComparer.Ordinal).ToArray();
        var items = matching.Skip(query.Offset).Take(query.Limit).ToImmutableArray();
        return new(snapshot.Id, snapshot.ObservedAt, snapshot.State, matching.Length, query.Offset, items,
            query.Offset + items.Length < matching.Length, snapshot.Sources, snapshot.Limitations);
    }

    public static string RegistrationId(StartupSource source, string key) => "startup_item_" + Convert.ToHexStringLower(SHA256.HashData(
        Encoding.UTF8.GetBytes(source + "\n" + (source is StartupSource.CurrentUserStartup or StartupSource.CommonStartup or StartupSource.PackagedStartupTasks ? key : key.ToUpperInvariant()))));
    internal static bool DisplayText(string? value, int maximum)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > maximum) return false;
        for (var index = 0; index < value.Length; index++)
        {
            var character = value[index];
            if (char.IsControl(character) || character is '\u202a' or '\u202b' or '\u202c' or '\u202d' or '\u202e' or '\u2066' or '\u2067' or '\u2068' or '\u2069') return false;
            if (!char.IsSurrogate(character)) continue;
            if (!char.IsHighSurrogate(character) || ++index >= value.Length || !char.IsLowSurrogate(value[index])) return false;
        }
        return true;
    }
    private static bool ValidIssues(ImmutableArray<string> issues) => !issues.IsDefault && issues.Length <= 16 && issues.All(code =>
        code is { Length: > 0 and <= 64 } && code.All(character => char.IsAsciiLetterLower(character) || char.IsAsciiDigit(character) || character == '_'));
    private static ShouException InvalidInventory() => new("startup_inventory_invalid", "Startup discovery did not describe bounded source coverage.");
}
