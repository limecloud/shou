using System.Collections.Immutable;
using System.Text;
using System.Text.Json;

namespace Shou.Windows.Core;

internal sealed class CleanupRecordCodec(RuleSchemaValidator validator)
{
    public const int MaximumPlanBytes = 134_217_728;
    public const int MaximumExecutionBytes = 1_048_576;
    public const int MaximumPlanItems = 256;
    public static readonly TimeSpan PlanLifetime = TimeSpan.FromMinutes(10);

    public static string ExecutionId(string planId) => "execution_" + planId[5..];
    public static string PlanDigest(CleanupPlan plan) => RecordJson.Digest(plan with { Digest = "" });

    public byte[] EncodePlan(CleanupPlan plan) { ValidatePlan(plan); return RecordJson.Encode(plan, MaximumPlanBytes); }
    public byte[] EncodeExecution(CleanupExecution execution, CleanupPlan plan) { ValidateExecution(execution, plan); return RecordJson.Encode(execution, MaximumExecutionBytes); }

    public CleanupPlan DecodePlan(byte[] bytes, string id) => Decode(() =>
    {
        if (bytes.Length > MaximumPlanBytes) throw Corrupt();
        var plan = JsonSerializer.Deserialize<CleanupPlan>(bytes, ContractJson.Options) ?? throw Corrupt();
        if (plan.Id != id) throw Corrupt();
        ValidatePlan(plan);
        return plan;
    });

    public CleanupExecution DecodeExecution(byte[] bytes, CleanupPlan plan) => Decode(() =>
    {
        if (bytes.Length > MaximumExecutionBytes) throw Corrupt();
        var execution = JsonSerializer.Deserialize<CleanupExecution>(bytes, ContractJson.Options) ?? throw Corrupt();
        ValidateExecution(execution, plan);
        return execution;
    });

    public CleanupExecution DecodeExecutionSummary(byte[] bytes, string id) => Decode(() =>
    {
        if (bytes.Length > MaximumExecutionBytes) throw Corrupt();
        var execution = JsonSerializer.Deserialize<CleanupExecution>(bytes, ContractJson.Options) ?? throw Corrupt();
        if (execution.Id != id) throw Corrupt();
        ValidateExecutionStructure(execution);
        return execution;
    });

    internal void ValidatePlan(CleanupPlan plan)
    {
        if (plan.Version is not (2 or 3) || !RecordKey.IsId(plan.Id, "plan") || plan.Budget is null || plan.Sources.IsDefaultOrEmpty ||
            plan.Sources.Length > MaximumPlanItems || !(RecordKey.IsId(plan.ConfigurationRevision, "config") || plan.Version == 3 && plan.ConfigurationRevision == "config_unconfigured") ||
            !RecordJson.IsDigest(plan.ConfigurationDigest) || !RecordJson.IsDigest(plan.Digest) ||
            plan.Items.IsDefaultOrEmpty || plan.Items.Length > MaximumPlanItems || !Enum.IsDefined(plan.Action) ||
            plan.CreatedAt.Offset != TimeSpan.Zero || plan.ExpiresAt.Offset != TimeSpan.Zero || plan.ExpiresAt - plan.CreatedAt != PlanLifetime) throw Corrupt();
        plan.Budget.Validate();
        var sources = new Dictionary<string, CleanupPlanSource>(StringComparer.Ordinal);
        var rules = new Dictionary<(string ScanId, string RuleId), CleanupRule>();
        foreach (var source in plan.Sources)
        {
            if (source is null || !RecordKey.IsId(source.ScanId, "scan") || source.Workspace is null || !sources.TryAdd(source.ScanId, source) ||
                source.Rules.IsDefault || (plan.Version == 2 ? source.Rules.IsEmpty : !source.Rules.IsEmpty || !source.Workspace.RootRef.StartsWith("storage-selection-", StringComparison.Ordinal) || source.Workspace.Path.IsVolumeRoot) ||
                source.Rules.Length > ConfigurationCodec.MaximumRules || !plan.Items.Any(item => item?.ScanId == source.ScanId)) throw Corrupt();
            foreach (var definition in source.Rules)
            {
                if (definition is null) throw Corrupt();
                var rule = validator.Parse(Encoding.UTF8.GetBytes(definition.Definition.GetRawText()));
                if (!rule.AppliesToWindows || rule.RootReference != source.Workspace.RootRef || definition.Digest != rule.Digest ||
                    !rules.TryAdd((source.ScanId, rule.Id), rule) || !plan.Items.Any(item => item is not null && item.ScanId == source.ScanId && item.RuleId == rule.Id)) throw Corrupt();
            }
        }
        new ConfigurationCodec(validator).Validate(new(1, plan.ConfigurationRevision, plan.Sources.Select(source => source.Workspace).ToImmutableArray(), [], [], []));
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var candidateIds = new HashSet<string>(StringComparer.Ordinal);
        var identities = new HashSet<FileIdentity>();
        var totalEntries = 0;
        foreach (var item in plan.Items)
        {
            if (item is null || !sources.TryGetValue(item.ScanId, out var source)) throw Corrupt();
            var workspace = source.Workspace;
            if (item is null || !RecordKey.IsId(item.Id, "item") || !RecordKey.IsId(item.CandidateId, "candidate") || !ids.Add(item.Id) || !candidateIds.Add(item.CandidateId) ||
                item.Path is null || !item.Path.IsWithin(workspace.Path, caseSensitive: true, includeRoot: false) || item.RelativePath != item.Path.RelativeTo(workspace.Path, caseSensitive: true) ||
                (plan.Version == 3 ? item.RuleId != "shou.storage-selection" || item.RuleVersion != "1.0.0" :
                    !rules.TryGetValue((item.ScanId, item.RuleId), out var rule) || item.RuleVersion != rule.Version) || item.Manifest.IsDefaultOrEmpty || item.Context.IsDefaultOrEmpty ||
                item.Risk is not ("review" or "high") || !RecordJson.IsDigest(item.ManifestDigest)) throw Corrupt();
            totalEntries = checked(totalEntries + item.Manifest.Length);
            if (totalEntries > plan.Budget.MaxEntries) throw Corrupt();
            var entries = new Dictionary<WindowsPath, FileEntry>();
            foreach (var entry in item.Manifest)
            {
                RequireEntry(entry, workspace);
                if (!entry.Path.IsWithin(item.Path, caseSensitive: true) || !entries.TryAdd(entry.Path, entry) || !identities.Add(entry.Identity)) throw Corrupt();
            }
            if (!entries.TryGetValue(item.Path, out var target) || (plan.Version == 2 && target.Kind != EntryKind.Directory) || item.Manifest[0].Path != item.Path ||
                !item.Manifest.Select(entry => entry.Path.Value).SequenceEqual(item.Manifest.Select(entry => entry.Path.Value).Order(StringComparer.Ordinal)) ||
                item.ManifestDigest != RuleClassifier.ManifestDigest(item.Manifest) || item.AllocatedBytes != item.Manifest.Sum(entry => entry.AllocatedBytes) ||
                item.LogicalBytes != item.Manifest.Sum(entry => entry.LogicalBytes)) throw Corrupt();
            var names = new Dictionary<WindowsPath, HashSet<string>>();
            foreach (var entry in entries.Values.Where(entry => entry.Path != item.Path))
            {
                if (entry.Path.Parent is not { } parent || !entries.TryGetValue(parent, out var directory) || directory.Kind != EntryKind.Directory) throw Corrupt();
                if (!names.TryGetValue(parent, out var siblings)) names[parent] = siblings = new(directory.IsCaseSensitive ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase);
                if (!siblings.Add(entry.Path.Name)) throw Corrupt();
            }
            var context = new Dictionary<WindowsPath, FileEntry>();
            foreach (var entry in item.Context)
            {
                RequireEntry(entry, workspace);
                if (!entry.Path.IsWithin(workspace.Path, caseSensitive: true) || entry.Path.IsWithin(item.Path, caseSensitive: true) || !context.TryAdd(entry.Path, entry)) throw Corrupt();
            }
            for (var parent = item.Path.Parent!; ; parent = parent.Parent!)
            {
                if (!context.TryGetValue(parent, out var directory) || directory.Kind != EntryKind.Directory) throw Corrupt();
                if (parent == workspace.Path) break;
            }
            if (context[workspace.Path].Identity != workspace.Identity || context[workspace.Path].IsCaseSensitive != workspace.CaseSensitive) throw Corrupt();
        }
        for (var index = 0; index < plan.Items.Length; index++)
            for (var other = index + 1; other < plan.Items.Length; other++)
                if (plan.Items[index].Path.IsWithin(plan.Items[other].Path) || plan.Items[other].Path.IsWithin(plan.Items[index].Path)) throw Corrupt();
        if (PlanDigest(plan) != plan.Digest) throw Corrupt();
    }

    private static void RequireEntry(FileEntry entry, Workspace workspace)
    {
        if (entry is null || entry.Path is null || entry.Identity is null || entry.Kind is not (EntryKind.Directory or EntryKind.File) ||
            entry.Identity.OwnerSid != workspace.Identity.OwnerSid || entry.Identity.VolumeSerialNumber != workspace.Identity.VolumeSerialNumber ||
            entry.Kind == EntryKind.File && entry.LinkCount != 1 || entry.LogicalBytes < 0 || entry.AllocatedBytes < 0 ||
            entry.LastWriteUtc.Offset != TimeSpan.Zero || entry.ChangeUtc.Offset != TimeSpan.Zero) throw Corrupt();
    }

    private static void ValidateExecution(CleanupExecution execution, CleanupPlan plan)
    {
        ValidateExecutionStructure(execution);
        if (execution.PlanId != plan.Id || execution.PlanDigest != plan.Digest || execution.Action != plan.Action ||
            execution.StartedAt < plan.CreatedAt || execution.StartedAt >= plan.ExpiresAt || execution.Items.Length != plan.Items.Length) throw Corrupt();
        for (var index = 0; index < execution.Items.Length; index++)
        {
            var item = execution.Items[index];
            var source = plan.Items[index];
            if (item.ItemId != source.Id || item.RemovedEntries > source.Manifest.Length ||
                item.State == CleanupItemState.Purged && item.RemovedEntries != source.Manifest.Length ||
                item.State == CleanupItemState.Trashed && (item.ResultPath == source.Path || item.ResultIdentity != source.Manifest[0].Identity)) throw Corrupt();
        }
    }

    private static void ValidateExecutionStructure(CleanupExecution execution)
    {
        if (execution.Version != 1 || !RecordKey.IsId(execution.PlanId, "plan") || execution.Id != ExecutionId(execution.PlanId) ||
            !RecordJson.IsDigest(execution.PlanDigest) || !Enum.IsDefined(execution.Action) ||
            execution.StartedAt.Offset != TimeSpan.Zero || execution.UpdatedAt.Offset != TimeSpan.Zero || execution.UpdatedAt < execution.StartedAt ||
            !Enum.IsDefined(execution.State) || execution.Items.IsDefaultOrEmpty || execution.Items.Length > MaximumPlanItems) throw Corrupt();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < execution.Items.Length; index++)
        {
            var item = execution.Items[index];
            if (item is null || !RecordKey.IsId(item.ItemId, "item") || !ids.Add(item.ItemId) || !Enum.IsDefined(item.State) || item.RemovedEntries < 0 ||
                item.Reason is not null && (item.Reason.Length is < 1 or > 80 || !item.Reason.All(character => char.IsAsciiLetterLower(character) || character == '_')) ||
                item.State is CleanupItemState.Pending or CleanupItemState.Purging or CleanupItemState.Moving or CleanupItemState.Skipped or CleanupItemState.Trashed && item.RemovedEntries != 0 ||
                item.State == CleanupItemState.Purged && (execution.Action != CleanupAction.Permanent || item.RemovedEntries == 0) ||
                item.State == CleanupItemState.Trashed && (execution.Action != CleanupAction.Trash || item.ResultPath is null || item.ResultIdentity is null) ||
                item.State != CleanupItemState.Trashed && (item.ResultPath is not null || item.ResultIdentity is not null) ||
                item.State == CleanupItemState.Purging && execution.Action != CleanupAction.Permanent || item.State == CleanupItemState.Moving && execution.Action != CleanupAction.Trash) throw Corrupt();
        }
        var unfinished = execution.Items.Any(item => item.State is CleanupItemState.Pending or CleanupItemState.Purging or CleanupItemState.Moving);
        var allDone = execution.Items.All(item => item.State is CleanupItemState.Purged or CleanupItemState.Trashed);
        if (execution.Items.Count(item => item.State is CleanupItemState.Purging or CleanupItemState.Moving) > 1) throw Corrupt();
        var expected = execution.Items.Any(item => item.State == CleanupItemState.Unknown) ? CleanupExecutionState.Unknown :
            allDone ? CleanupExecutionState.Completed :
            execution.Items.Any(item => item.State == CleanupItemState.Cancelled) && !execution.Items.Any(item => item.State == CleanupItemState.Failed) ? CleanupExecutionState.Cancelled : CleanupExecutionState.Partial;
        if (execution.State != CleanupExecutionState.Executing && (unfinished || execution.State != expected)) throw Corrupt();
    }

    private static T Decode<T>(Func<T> read)
    {
        try { return read(); }
        catch (ShouException error) when (error.Code != "store_corrupt") { throw Corrupt(error); }
        catch (Exception error) when (error is JsonException or InvalidOperationException or ArgumentException or NullReferenceException or OverflowException) { throw Corrupt(error); }
    }
    private static ShouException Corrupt(Exception? error = null) => new("store_corrupt", "The cleanup record is invalid or unsupported.", error);
}
