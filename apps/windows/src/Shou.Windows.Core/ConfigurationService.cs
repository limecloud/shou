using System.Collections.Immutable;
using System.Text;

namespace Shou.Windows.Core;

public sealed class ConfigurationService(IRecordStore store, RuleSchemaValidator validator, IWindowsFileSystem fileSystem,
    string ownerSid, TimeProvider? timeProvider = null, BuiltinRuleCatalog? catalog = null)
{
    private readonly ConfigurationCodec codec = new(validator);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async Task<Configuration> ReadAsync(CancellationToken cancellationToken = default) =>
        codec.Decode(await store.ReadAsync("configuration", ConfigurationCodec.MaximumBytes, cancellationToken));

    public async Task<Workspace> WorkspaceAsync(string id, CancellationToken cancellationToken = default) =>
        Find(await ReadAsync(cancellationToken), id);

    public async Task<RuleRecord> RuleAsync(string id, string? version = null, CancellationToken cancellationToken = default) =>
        FindRule(await ReadAsync(cancellationToken), id, version);

    public async Task<bool> IsAccessibleAsync(Workspace workspace, CancellationToken cancellationToken = default)
    {
        try
        {
            var current = await fileSystem.InspectAsync(workspace.Path, cancellationToken);
            return current.Kind == EntryKind.Directory && current.Identity == workspace.Identity && current.IsCaseSensitive == workspace.CaseSensitive;
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException) { return false; }
    }

    public async Task<Workspace> AddWorkspaceAsync(WindowsPath path, string rootRef, CancellationToken cancellationToken = default)
    {
        if (!ConfigurationCodec.ValidRootRef(rootRef) || path.IsVolumeRoot) throw Input("Choose a local directory and a valid logical root reference.");
        var current = await fileSystem.InspectAsync(path, cancellationToken);
        if (current.Path != path || current.Kind != EntryKind.Directory || current.Identity.OwnerSid != ownerSid)
            throw new ShouException("permission_denied", "The workspace must be a verified local directory owned by the current user.");
        var workspace = new Workspace(RecordKey.New("ws"), rootRef, path, current.Identity, current.IsCaseSensitive, [], clock.GetUtcNow());
        return await UpdateAsync(configuration =>
        {
            if (configuration.Workspaces.Length >= ConfigurationCodec.MaximumWorkspaces) throw Limit();
            if (configuration.Workspaces.Any(existing => existing.RootRef == rootRef || existing.Identity == current.Identity))
                throw Input("The workspace or root reference is already registered.");
            return (configuration with { Workspaces = configuration.Workspaces.Add(workspace) }, workspace);
        }, cancellationToken);
    }

    public Task<bool> RemoveWorkspaceAsync(string id, CancellationToken cancellationToken = default) => UpdateAsync(configuration =>
    {
        _ = Find(configuration, id);
        return (configuration with
        {
            Workspaces = configuration.Workspaces.Where(workspace => workspace.Id != id).ToImmutableArray(),
            Bindings = configuration.Bindings.Where(binding => binding.WorkspaceId != id).ToImmutableArray()
        }, true);
    }, cancellationToken);

    public async Task<ImmutableArray<Workspace>> RegisterDiscoveredAsync(ImmutableArray<Workspace> proposed, string expectedRevision, CancellationToken cancellationToken = default)
    {
        if (proposed.IsDefault || proposed.Length > ConfigurationCodec.MaximumWorkspaces) throw Limit();
        foreach (var workspace in proposed)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (workspace.Path.IsVolumeRoot || workspace.Identity.OwnerSid != ownerSid || !ConfigurationCodec.ValidRootRef(workspace.RootRef)) throw Input("Choose a verified local scan location.");
            var current = await fileSystem.InspectAsync(workspace.Path, cancellationToken);
            if (current.Path != workspace.Path || current.Kind != EntryKind.Directory || current.Identity != workspace.Identity || current.IsCaseSensitive != workspace.CaseSensitive)
                throw new ShouException("source_changed", "A discovered directory changed before registration.");
        }
        return await UpdateAsync(configuration =>
        {
            if (configuration.Revision != expectedRevision) throw new ShouException("plan_stale", "Configuration changed during discovery. Refresh scan locations.");
            var all = configuration.Workspaces;
            var selected = ImmutableArray.CreateBuilder<Workspace>();
            foreach (var candidate in proposed)
            {
                var existing = all.FirstOrDefault(value => value.Path == candidate.Path);
                if (existing is not null)
                {
                    if (existing.Identity != candidate.Identity || existing.CaseSensitive != candidate.CaseSensitive) throw new ShouException("source_changed", "A registered directory changed identity.");
                    selected.Add(existing);
                    continue;
                }
                if (!candidate.RootRef.StartsWith("shou-location-", StringComparison.Ordinal) || all.Any(value => value.RootRef == candidate.RootRef || value.Identity == candidate.Identity ||
                    value.Path.IsWithin(candidate.Path) || candidate.Path.IsWithin(value.Path))) throw new ShouException("plan_stale", "A discovered directory conflicts with a registered scope.");
                if (all.Length >= ConfigurationCodec.MaximumWorkspaces) throw Limit();
                var workspace = candidate with { Id = RecordKey.New("ws"), Exclusions = [], AddedAt = clock.GetUtcNow() };
                all = all.Add(workspace); selected.Add(workspace);
            }
            return (all.Equals(configuration.Workspaces) ? configuration : configuration with { Workspaces = all }, selected.ToImmutable());
        }, cancellationToken);
    }

    public Task<RuleRecord> ImportRuleAsync(ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken = default)
    {
        var rule = validator.Parse(bytes);
        if (rule.Id.StartsWith("shou.builtin.", StringComparison.Ordinal)) throw new ShouException("invalid_rule", "The built-in rule namespace is reserved.");
        return UpdateAsync(configuration =>
        {
            var existing = configuration.Rules.FirstOrDefault(record => record.Rule.GetProperty("id").GetString() == rule.Id && record.Rule.GetProperty("version").GetString() == rule.Version);
            if (existing is not null)
            {
                if (existing.Digest != rule.Digest) throw new ShouException("version_conflict", "This rule version already exists with different content. Choose a new version.");
                return (configuration, existing);
            }
            if (configuration.Rules.Length >= ConfigurationCodec.MaximumRules) throw Limit();
            var record = new RuleRecord(rule.Definition, rule.Digest, clock.GetUtcNow(), "local_file");
            return (configuration with { Rules = configuration.Rules.Add(record) }, record);
        }, cancellationToken);
    }

    public Task<RuleBinding> SetRuleAsync(string workspaceId, string ruleId, bool enabled, string? version = null, CancellationToken cancellationToken = default) => UpdateAsync(configuration =>
    {
        var workspace = Find(configuration, workspaceId);
        var rule = ruleId.StartsWith(BuiltinRuleCatalog.Prefix, StringComparison.Ordinal)
            ? catalog?.RulesFor(workspace).FirstOrDefault(value => value.Id == ruleId && (version is null || value.Version == version)) ?? throw Input("Unknown or inapplicable built-in rule version.")
            : validator.Parse(Encoding.UTF8.GetBytes(FindRule(configuration, ruleId, version).Rule.GetRawText()));
        if (rule.RootReference != workspace.RootRef || !rule.AppliesToWindows)
            throw new ShouException("invalid_rule", "The rule root or platform does not match this workspace.");
        var binding = new RuleBinding(workspaceId, rule.Id, rule.Version, rule.Digest, enabled);
        if (configuration.Bindings.Contains(binding)) return (configuration, binding);
        var bindings = configuration.Bindings.Where(existing => existing.WorkspaceId != workspaceId || existing.RuleId != ruleId).Append(binding).ToImmutableArray();
        if (bindings.Length > ConfigurationCodec.MaximumBindings) throw Limit();
        return (configuration with { Bindings = bindings }, binding);
    }, cancellationToken);

    public Task<ImmutableArray<string>> SetExclusionAsync(string? workspaceId, string pattern, bool remove,
        string? project = null, CancellationToken cancellationToken = default)
    {
        if (project is not null && workspaceId is null) throw Input("Project exclusions require a workspace.");
        pattern = ResolveExclusionPattern(pattern, project);
        return UpdateAsync(configuration =>
        {
            var workspace = workspaceId is null ? null : Find(configuration, workspaceId);
            var previous = workspace?.Exclusions ?? configuration.GlobalExclusions;
            var next = remove ? previous.Where(value => value != pattern).ToImmutableArray() : previous.Contains(pattern) ? previous : previous.Add(pattern);
            if (next.Length > ConfigurationCodec.MaximumExclusions) throw Limit();
            if (previous.SequenceEqual(next)) return (configuration, previous);
            return (workspace is null ? configuration with { GlobalExclusions = next } : configuration with
            {
                Workspaces = configuration.Workspaces.Select(value => value.Id == workspace.Id ? value with { Exclusions = next } : value).ToImmutableArray()
            }, next);
        }, cancellationToken);
    }

    public static string ResolveExclusionPattern(string pattern, string? project = null)
    {
        if (project is not null)
        {
            WindowsPath.ValidateRelative(project);
            if (project.Contains('*') || project.Contains('?')) throw Input("Choose an exact project path.");
            pattern = project + "/" + pattern;
        }
        _ = new RulePattern(pattern);
        return pattern;
    }

    public async Task<ExclusionSettings> ExclusionsAsync(string? workspaceId = null, CancellationToken cancellationToken = default)
    {
        var configuration = await ReadAsync(cancellationToken);
        return new(configuration.GlobalExclusions, workspaceId, workspaceId is null ? [] : Find(configuration, workspaceId).Exclusions);
    }

    public async Task<ImmutableArray<CleanupRule>> BuiltinRulesAsync(string workspaceId, CancellationToken cancellationToken = default) =>
        catalog?.RulesFor(await WorkspaceAsync(workspaceId, cancellationToken)) ?? [];

    private Task<T> UpdateAsync<T>(Func<Configuration, (Configuration Configuration, T Result)> update, CancellationToken cancellationToken) =>
        store.UpdateAsync(transaction =>
        {
            var previous = codec.Decode(transaction.Read("configuration", ConfigurationCodec.MaximumBytes));
            var (next, result) = update(previous);
            if (!ReferenceEquals(previous, next))
                transaction.Write("configuration", codec.Encode(next with { Revision = RecordKey.New("config") }));
            return result;
        }, cancellationToken);

    private static Workspace Find(Configuration configuration, string id) => configuration.Workspaces.FirstOrDefault(workspace => workspace.Id == id) ?? throw Input("Unknown workspace.");
    private static RuleRecord FindRule(Configuration configuration, string id, string? version) => configuration.Rules
        .Where(record => record.Rule.GetProperty("id").GetString() == id && (version is null || record.Rule.GetProperty("version").GetString() == version))
        .OrderBy(record => record.ImportedAt).LastOrDefault() ?? throw Input("Unknown rule or version.");
    private static ShouException Input(string message) => new("invalid_argument", message);
    private static ShouException Limit() => new("resource_limit", "The configuration has reached its supported record limit.");
}
