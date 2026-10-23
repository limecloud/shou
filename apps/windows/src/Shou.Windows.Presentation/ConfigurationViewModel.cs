using System.Collections.Immutable;
using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public interface IConfigurationOperations
{
    Task<Configuration> ReadConfigurationAsync(CancellationToken cancellationToken);
    Task<Workspace> AddWorkspaceAsync(WindowsPath path, string rootReference, CancellationToken cancellationToken);
    Task<bool> RemoveWorkspaceAsync(string workspaceId, CancellationToken cancellationToken);
    Task<RuleRecord> ImportRuleAsync(ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken);
    Task<RuleBinding> SetRuleAsync(string workspaceId, string ruleId, string version, bool enabled, CancellationToken cancellationToken);
    Task<ImmutableArray<string>> SetExclusionAsync(string? workspaceId, string pattern, bool remove, CancellationToken cancellationToken);
}

public sealed record RuleVersionChoice(string Id, string Version, string Name, string Description, string RootReference,
    bool AppliesToWindows, string Risk, string Digest, bool Builtin = false)
{
    public string Label => Name + " · " + Version;
    internal static RuleVersionChoice From(RuleRecord record)
    {
        var rule = record.Rule;
        return new(rule.GetProperty("id").GetString()!, rule.GetProperty("version").GetString()!, rule.GetProperty("name").GetString()!,
            rule.GetProperty("description").GetString()!, rule.GetProperty("scope").GetProperty("root_ref").GetString()!,
            rule.GetProperty("platforms").EnumerateArray().Any(value => value.GetString() == "windows"),
            rule.GetProperty("risk").GetProperty("declared_level").GetString()!, record.Digest);
    }
    internal static RuleVersionChoice From(CleanupRule rule) => From(new RuleRecord(rule.Definition, rule.Digest, DateTimeOffset.UnixEpoch, "builtin")) with { Builtin = true };
}

public enum ConfigurationPageState { Empty, Loading, Ready, Saving, Failed }

/// <summary>Serializes configuration writes and reconciles persisted state, including ambiguous failures.</summary>
public sealed class ConfigurationViewModel(IConfigurationOperations operations, BuiltinRuleCatalog? catalog = null) : INotifyPropertyChanged, IDisposable
{
    private CancellationTokenSource? read;
    private bool disposed;
    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? EvidenceInvalidated;
    public ConfigurationPageState State { get; private set; }
    public Configuration? Snapshot { get; private set; }
    public string? ErrorCode { get; private set; }
    public string? RefreshErrorCode { get; private set; }
    public string? WorkspaceId { get; private set; }
    public RuleVersionChoice? SelectedRule { get; private set; }
    public bool IsBusy => State is ConfigurationPageState.Loading or ConfigurationPageState.Saving;
    public bool IsSaving => State == ConfigurationPageState.Saving;
    public bool CanEdit => !IsBusy && Snapshot is not null;
    public ImmutableArray<Workspace> Workspaces => Snapshot?.Workspaces ?? [];
    public ImmutableArray<RuleVersionChoice> Rules { get; private set; } = [];
    public Workspace? SelectedWorkspace => Workspaces.FirstOrDefault(value => value.Id == WorkspaceId);
    public RuleBinding? SelectedBinding
    {
        get
        {
            var binding = Snapshot?.Bindings.FirstOrDefault(value => value.WorkspaceId == WorkspaceId && value.RuleId == SelectedRule?.Id);
            return SelectedRule is { Builtin: true } rule && WorkspaceId is { } id
                ? new(id, rule.Id, rule.Version, rule.Digest, binding?.Enabled ?? true) : binding;
        }
    }
    public bool CanAddLocation => CanEdit && SelectedRule is { AppliesToWindows: true, Builtin: false } rule && !Workspaces.Any(value => value.RootRef == rule.RootReference);
    public bool CanEnable => CanEdit && SelectedRule is { AppliesToWindows: true } rule && SelectedWorkspace?.RootRef == rule.RootReference &&
        !(SelectedBinding is { Enabled: true } binding && binding.Version == rule.Version);
    public bool CanDisable => CanEdit && SelectedRule is { } rule && SelectedBinding is { Enabled: true } binding && binding.Version == rule.Version;
    public ImmutableArray<string> GlobalExclusions => Snapshot?.GlobalExclusions ?? [];
    public ImmutableArray<string> WorkspaceExclusions => SelectedWorkspace?.Exclusions ?? [];

    public async Task LoadAsync()
    {
        EnsureIdle();
        State = ConfigurationPageState.Loading;
        ErrorCode = null;
        RefreshErrorCode = null;
        using var current = new CancellationTokenSource();
        read = current;
        NotifyAll();
        EvidenceInvalidated?.Invoke(this, EventArgs.Empty);
        try
        {
            var value = await operations.ReadConfigurationAsync(current.Token);
            current.Token.ThrowIfCancellationRequested();
            if (disposed) return;
            Apply(value);
            State = ConfigurationPageState.Ready;
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested)
        {
            if (!disposed) { Clear(); State = ConfigurationPageState.Empty; }
        }
        catch (Exception error) when (Expected(error))
        {
            if (!disposed) { Clear(); ErrorCode = Code(error); State = ConfigurationPageState.Failed; }
        }
        finally
        {
            if (!disposed) { read = null; NotifyAll(); }
        }
    }

    public void SelectWorkspace(string? workspaceId)
    {
        EnsureIdle();
        if (workspaceId is not null && !Workspaces.Any(value => value.Id == workspaceId)) throw Invalid();
        WorkspaceId = workspaceId;
        RebuildRules();
        NotifyAll();
    }

    public void SelectRule(string id, string version)
    {
        EnsureIdle();
        SelectedRule = Rules.FirstOrDefault(value => value.Id == id && value.Version == version) ?? throw Invalid();
        if (!SelectedRule.Builtin) WorkspaceId = Workspaces.FirstOrDefault(value => value.RootRef == SelectedRule.RootReference)?.Id;
        RebuildRules();
        NotifyAll();
    }

    public Task ImportRuleAsync(ReadOnlyMemory<byte> bytes) => SaveAsync(async () =>
    {
        var record = await operations.ImportRuleAsync(bytes, CancellationToken.None);
        var choice = RuleVersionChoice.From(record);
        return configuration =>
        {
            SelectedRule = Rules.FirstOrDefault(value => value.Id == choice.Id && value.Version == choice.Version);
            WorkspaceId = configuration.Workspaces.FirstOrDefault(value => value.RootRef == choice.RootReference)?.Id;
            RebuildRules();
        };
    });

    public Task AddLocationAsync(WindowsPath path)
    {
        EnsureIdle();
        if (!CanAddLocation || SelectedRule is not { } rule) throw Invalid();
        return SaveAsync(async () =>
        {
            var workspace = await operations.AddWorkspaceAsync(path, rule.RootReference, CancellationToken.None);
            return _ => { WorkspaceId = Workspaces.FirstOrDefault(value => value.Id == workspace.Id)?.Id; RebuildRules(); };
        });
    }

    public Task RemoveLocationAsync()
    {
        EnsureIdle();
        var id = SelectedWorkspace?.Id ?? throw Invalid();
        return SaveAsync(async () => { await operations.RemoveWorkspaceAsync(id, CancellationToken.None); return null; });
    }

    public Task SetRuleAsync(bool enabled)
    {
        EnsureIdle();
        if (!(enabled ? CanEnable : CanDisable) || SelectedRule is not { } rule || WorkspaceId is not { } workspaceId) throw Invalid();
        return SaveAsync(async () =>
        {
            await operations.SetRuleAsync(workspaceId, rule.Id, rule.Version, enabled, CancellationToken.None);
            return null;
        });
    }

    public string PreviewExclusion(string pattern, bool allLocations, string? project = null)
    {
        EnsureIdle();
        if (!CanEdit || !allLocations && SelectedWorkspace is null || allLocations && project is not null) throw Invalid();
        try { return ConfigurationService.ResolveExclusionPattern(pattern, project); }
        catch (ShouException error) when (error.Code == "invalid_rule")
        { throw new ShouException("invalid_argument", "Choose a valid relative exclusion pattern.", error); }
    }

    public Task AddExclusionAsync(string pattern, bool allLocations, string? project = null)
    {
        var resolved = PreviewExclusion(pattern, allLocations, project);
        return ChangeExclusionAsync(resolved, allLocations, remove: false);
    }

    public Task RemoveExclusionAsync(string pattern, bool allLocations)
    {
        EnsureIdle();
        if (!(allLocations ? GlobalExclusions : WorkspaceExclusions).Contains(pattern)) throw Invalid();
        return ChangeExclusionAsync(pattern, allLocations, remove: true);
    }

    private Task ChangeExclusionAsync(string pattern, bool allLocations, bool remove)
    {
        EnsureIdle();
        if (!CanEdit || !allLocations && WorkspaceId is null) throw Invalid();
        var id = allLocations ? null : WorkspaceId;
        return SaveAsync(async () => { await operations.SetExclusionAsync(id, pattern, remove, CancellationToken.None); return null; });
    }

    private async Task SaveAsync(Func<Task<Action<Configuration>?>> save)
    {
        EnsureIdle();
        if (!CanEdit) throw Invalid();
        State = ConfigurationPageState.Saving;
        ErrorCode = null;
        RefreshErrorCode = null;
        NotifyAll();
        // A failed/cancelled response does not prove that a write did not commit.
        EvidenceInvalidated?.Invoke(this, EventArgs.Empty);
        Action<Configuration>? after = null;
        var completed = false;
        try { after = await save(); completed = true; }
        catch (Exception error) when (Expected(error) || error is OperationCanceledException)
        { if (!disposed) ErrorCode = Code(error); }
        finally
        {
            try
            {
                var value = await operations.ReadConfigurationAsync(CancellationToken.None);
                if (!disposed) { Apply(value); after?.Invoke(value); }
            }
            catch (Exception error) when (Expected(error) || error is OperationCanceledException)
            { if (!disposed) { Clear(); RefreshErrorCode = Code(error); } }
            if (!disposed)
            {
                State = completed && ErrorCode is null && RefreshErrorCode is null ? ConfigurationPageState.Ready : ConfigurationPageState.Failed;
                NotifyAll();
            }
        }
    }

    private void Apply(Configuration configuration)
    {
        Snapshot = configuration;
        WorkspaceId = Workspaces.Any(value => value.Id == WorkspaceId) ? WorkspaceId : null;
        RebuildRules();
    }

    private void RebuildRules()
    {
        var previous = SelectedRule;
        var builtins = SelectedWorkspace is { } workspace ? catalog?.RulesFor(workspace) ?? [] : [];
        Rules = (Snapshot?.Rules ?? []).Select(RuleVersionChoice.From).Concat(builtins.Select(RuleVersionChoice.From))
            .OrderBy(value => value.Name, StringComparer.Ordinal).ThenBy(value => value.Id, StringComparer.Ordinal).ThenBy(value => value.Version, StringComparer.Ordinal).ToImmutableArray();
        SelectedRule = previous is null ? null : Rules.FirstOrDefault(value => value.Id == previous.Id && value.Version == previous.Version && value.Builtin == previous.Builtin);
    }

    private void Clear() { Snapshot = null; Rules = []; SelectedRule = null; WorkspaceId = null; }
    private void EnsureIdle()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsBusy) throw new ShouException("store_busy", "Wait for the configuration operation to finish.");
    }
    private static bool Expected(Exception error) => error is ShouException or IOException or UnauthorizedAccessException;
    private static string Code(Exception error) => error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" :
        error is OperationCanceledException ? "operation_cancelled" : "read_failed";
    private static ShouException Invalid() => new("invalid_argument", "Choose a current rule, scan location and supported configuration action.");
    private void NotifyAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        read?.Cancel();
        read = null;
        GC.SuppressFinalize(this);
    }
}
