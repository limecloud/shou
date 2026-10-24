using System.Collections.Immutable;
using System.Text;

namespace Shou.Windows.Core;

public sealed class CleanupService(IRecordStore store, RuleSchemaValidator validator, IStorageScanner scanner,
    CleanupProtectionContext protection, ICleanupActivity activity, ICleanupMutation mutation, TimeProvider? timeProvider = null, BuiltinRuleCatalog? catalog = null)
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly ConfigurationCodec configurationCodec = new(validator);
    private readonly CleanupRecordCodec records = new(validator);
    private readonly CleanupPlanRecords plans = new(new CleanupRecordCodec(validator));
    private readonly CleanupScanService scans = new(store, validator, scanner, protection, timeProvider, catalog);
    private readonly Guid confirmationIssuer = Guid.NewGuid();

    public Task<CleanupPlan> CreatePlanAsync(string scanId, IEnumerable<string> candidateIds,
        CleanupAction action = CleanupAction.Permanent, CancellationToken cancellationToken = default) =>
        CreatePlanAsync([new CleanupSelection(scanId, candidateIds.Take(CleanupRecordCodec.MaximumPlanItems + 1).ToImmutableArray())], action, cancellationToken);

    public async Task<CleanupPlan> CreatePlanAsync(IEnumerable<CleanupSelection> selections,
        CleanupAction action = CleanupAction.Permanent, CancellationToken cancellationToken = default)
    {
        var selection = selections.Take(CleanupRecordCodec.MaximumPlanItems + 1).ToArray();
        if (!Enum.IsDefined(action) || selection.Length is < 1 or > CleanupRecordCodec.MaximumPlanItems ||
            selection.Any(value => value is null || !RecordKey.IsId(value.ScanId, "scan") || value.CandidateIds.IsDefaultOrEmpty ||
                value.CandidateIds.Length > CleanupRecordCodec.MaximumPlanItems || value.CandidateIds.Any(id => !RecordKey.IsId(id, "candidate"))) ||
            selection.Select(value => value.ScanId).Distinct(StringComparer.Ordinal).Count() != selection.Length ||
            selection.Sum(value => value.CandidateIds.Length) > CleanupRecordCodec.MaximumPlanItems ||
            selection.SelectMany(value => value.CandidateIds).Distinct(StringComparer.Ordinal).Count() != selection.Sum(value => value.CandidateIds.Length))
            throw Input("Choose between 1 and 256 distinct candidates, each bound to exactly one scan.");
        RequireSupported(action);
        var started = clock.GetTimestamp();
        await using var lease = await store.AcquireLeaseAsync(cancellationToken);
        var configuration = await ReadConfigurationAsync(lease, cancellationToken);
        var sources = new List<(CleanupScan Scan, ImmutableArray<string> Selected)>();
        var sourceEntries = 0;
        foreach (var value in selection.OrderBy(value => value.ScanId, StringComparer.Ordinal))
        {
            var sourceRecordBytes = await lease.ReadAsync(value.ScanId, CleanupScanService.MaximumSnapshotBytes, cancellationToken) ?? throw Input("The scan does not exist.");
            var source = await CleanupScanRecords.ReadAsync(sourceRecordBytes, value.ScanId, lease, scans, cancellationToken);
            sourceEntries = checked(sourceEntries + source.Scan.Entries.Length);
            if (sourceEntries > 1_000_000) throw new ShouException("resource_limit", "The combined scan evidence exceeds the read budget. Select fewer locations.");
            if (source.PreviewOnly) throw new ShouException("preview_only", "Draft previews cannot authorize a plan. Import, explicitly enable and scan the rule first.");
            _ = CurrentWorkspace(configuration, source.Workspace, source.ConfigurationDigest);
            if (sources.Any(value => value.Scan.WorkspaceId == source.WorkspaceId)) throw Input("Choose one current scan per location.");
            sources.Add((source, value.CandidateIds));
        }
        // One request has a shared validation budget, rather than multiplying it by the number of locations.
        var budget = new ScanBudget(sources.Max(value => value.Scan.Budget.MaxEntries), sources.Max(value => value.Scan.Budget.MaxDepth),
            sources.Max(value => value.Scan.Budget.Duration));
        var validation = new ValidationBudget(budget, clock, started);
        var items = ImmutableArray.CreateBuilder<CleanupPlanItem>();
        var planSources = ImmutableArray.CreateBuilder<CleanupPlanSource>();
        foreach (var (source, selected) in sources)
        {
            var workspace = source.Workspace;
            var sourceIndex = new FileTreeIndex(source.Scan);
            var enabled = scans.EnabledRules(configuration, workspace.Id);
            if (!SameRules(source.Rules, enabled)) throw Stale();
            var reproduced = scans.Classify(configuration, workspace, enabled, source.Scan, validation.Remaining(), cancellationToken, sourceIndex);
            var original = selected.Select(id =>
            {
                if (!source.Candidates.Any(candidate => candidate.Id == id)) throw Input("The selected candidate is not in its bound scan.");
                var candidate = reproduced.Candidates.FirstOrDefault(candidate => candidate.Id == id) ?? throw Stale();
                RequireCandidate(candidate);
                return candidate;
            }).OrderBy(candidate => candidate.Path.Value, StringComparer.Ordinal).ToArray();
            var current = await ObserveAsync(configuration, workspace, enabled, validation, cancellationToken);
            foreach (var candidate in original)
            {
                if (items.Any(item => Overlap(item.Path, candidate.Path))) throw Input("Choose non-overlapping targets across all locations.");
                var observed = FindCurrent(current.Classification, candidate.RuleId, candidate.Path);
                RequireCandidate(observed);
                if (candidate.ManifestDigest != observed.ManifestDigest) throw Stale();
                var rule = enabled.Single(rule => rule.Id == candidate.RuleId);
                var context = Context(source.Scan, sourceIndex, candidate.Path, rule);
                RequireContext(context, current.Index);
                var item = new CleanupPlanItem(RecordKey.New("item"), source.Id, candidate.Id, rule.Id, rule.Version, candidate.RelativePath, candidate.Path,
                    current.Index.Manifest(candidate.Path), context, observed.ManifestDigest!, observed.AllocatedBytes, observed.LogicalBytes, observed.Risk);
                await RequireIdleAsync(workspace, item, cancellationToken);
                items.Add(item);
            }
            planSources.Add(new(source.Id, workspace, enabled.Where(rule => original.Any(item => item.RuleId == rule.Id))
                .Select(rule => new ScanRule(rule.Definition, rule.Digest)).ToImmutableArray()));
        }
        cancellationToken.ThrowIfCancellationRequested();
        _ = validation.Remaining();
        var now = clock.GetUtcNow();
        var plan = new CleanupPlan(2, RecordKey.New("plan"), planSources.ToImmutable(), budget, configuration.Revision,
            configurationCodec.Digest(configuration), now, now + CleanupRecordCodec.PlanLifetime, action, items.ToImmutable(), "");
        plan = plan with { Digest = CleanupRecordCodec.PlanDigest(plan) };
        if (await lease.ReadAsync(plan.Id, CleanupRecordCodec.MaximumPlanBytes, cancellationToken) is not null) throw new ShouException("version_conflict", "A plan with this identifier already exists.");
        await plans.SaveAsync(lease, plan, cancellationToken);
        return plan;
    }

    public async Task<CleanupPlan> PlanAsync(string planId, CancellationToken cancellationToken = default)
    {
        ValidatePlanId(planId);
        await using var lease = await store.AcquireReadLeaseAsync(cancellationToken) ?? throw Input("The plan does not exist.");
        return await plans.ReadAsync(lease, planId, cancellationToken);
    }

    public async Task<CleanupExecution?> ExecutionAsync(string planId, CancellationToken cancellationToken = default)
    {
        var plan = await PlanAsync(planId, cancellationToken);
        var bytes = await store.ReadAsync(CleanupRecordCodec.ExecutionId(planId), CleanupRecordCodec.MaximumExecutionBytes, cancellationToken);
        return bytes is null ? null : records.DecodeExecution(bytes, plan);
    }

    public async Task<CleanupConsent> ConfirmAsync(string planId, ICleanupConfirmation confirmation, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(confirmation);
        var plan = await PlanAsync(planId, cancellationToken);
        RequireCurrentTime(plan);
        RequireSupported(plan.Action);
        if (await store.ReadAsync(CleanupRecordCodec.ExecutionId(plan.Id), CleanupRecordCodec.MaximumExecutionBytes, cancellationToken) is not null) throw Consumed();
        var configuration = configurationCodec.Decode(await store.ReadAsync("configuration", ConfigurationCodec.MaximumBytes, cancellationToken));
        RequireSources(configuration, plan);
        RequireBindings(configuration, plan);
        var review = new CleanupReview(plan.Id, plan.Digest, plan.Action, plan.ExpiresAt,
            plan.Items.Select(item => new CleanupReviewItem(item.Id, item.Path, item.RuleId, item.Risk, item.AllocatedBytes, item.Manifest.Length)).ToImmutableArray());
        if (!await confirmation.RequestAsync(review, cancellationToken)) throw new ShouException("confirmation_required", "The current plan was not confirmed.");
        cancellationToken.ThrowIfCancellationRequested();
        RequireCurrentTime(plan);
        return new(confirmationIssuer, plan, new[] { plan.ExpiresAt, clock.GetUtcNow() + TimeSpan.FromMinutes(1) }.Min());
    }

    public async Task<CleanupExecution> ExecuteAsync(string planId, CleanupConsent? consent, IProgress<CleanupProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        progress = progress is null ? null : new ThrottledProgress(progress, clock);
        ValidatePlanId(planId);
        if (consent is null) throw new ShouException("confirmation_required", "Confirm the current plan before execution.");
        await using var lease = await store.AcquireLeaseAsync(cancellationToken);
        var plan = await plans.ReadAsync(lease, planId, cancellationToken);
        RequireCurrentTime(plan);
        RequireSupported(plan.Action);
        if (await lease.ReadAsync(CleanupRecordCodec.ExecutionId(plan.Id), CleanupRecordCodec.MaximumExecutionBytes, cancellationToken) is not null) throw Consumed();
        consent.Consume(confirmationIssuer, plan, clock.GetUtcNow());
        var validation = new ValidationBudget(plan.Budget, clock);
        var configuration = await ReadConfigurationAsync(lease, cancellationToken);
        RequireSources(configuration, plan);
        RequireBindings(configuration, plan);
        Report(progress, new("preflight", null, null, 0, plan.Items.Length));
        // Revalidate every selected location before persisting intent or changing any target.
        foreach (var source in plan.Sources)
        {
            var preflight = await ObserveAsync(configuration, source.Workspace, ParseRules(source), validation, cancellationToken,
                new InlineProgress<ScanProgress>(value => Report(progress, new("checking", null, value.CurrentPath, 0, plan.Items.Length, 0, plan.Items.Sum(item => item.Manifest.Length)))));
            foreach (var item in plan.Items.Where(item => item.ScanId == source.ScanId))
            {
                VerifyItem(item, preflight);
                await RequireIdleAsync(source.Workspace, item, cancellationToken);
            }
        }
        cancellationToken.ThrowIfCancellationRequested();
        RequireCurrentTime(plan);
        var now = clock.GetUtcNow();
        var execution = new CleanupExecution(1, CleanupRecordCodec.ExecutionId(plan.Id), plan.Id, plan.Digest, plan.Action, now, now,
            CleanupExecutionState.Executing, plan.Items.Select(item => new CleanupItemResult(item.Id, CleanupItemState.Pending)).ToImmutableArray());
        await SaveExecutionAsync(lease, execution, plan);
        for (var index = 0; index < plan.Items.Length; index++)
        {
            var item = plan.Items[index];
            var source = plan.Sources.Single(value => value.ScanId == item.ScanId);
            if (cancellationToken.IsCancellationRequested)
            {
                execution = StopRemaining(execution, index, CleanupItemState.Cancelled, "cancelled");
                break;
            }
            try
            {
                RequireCurrentTime(plan);
                // Configuration is stable under this lease. Native adapters own the final exact-tree check.
                if (!mutation.VerifiesMutationManifest)
                {
                    var current = await ObserveAsync(configuration, source.Workspace, ParseRules(source), validation, cancellationToken);
                    VerifyItem(item, current);
                }
                await RequireIdleAsync(source.Workspace, item, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                execution = StopRemaining(execution, index, CleanupItemState.Cancelled, "cancelled");
                break;
            }
            catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
            {
                execution = SetItem(execution, index, new(item.Id, CleanupItemState.Failed, Reason: Reason(error)));
                execution = StopRemaining(execution, index + 1, CleanupItemState.Skipped, "preflight_failed");
                await SaveExecutionAsync(lease, execution, plan);
                break;
            }
            var intent = plan.Action == CleanupAction.Permanent ? CleanupItemState.Purging : CleanupItemState.Moving;
            execution = SetItem(execution, index, new(item.Id, intent));
            await SaveExecutionAsync(lease, execution, plan);
            Report(progress, new(intent == CleanupItemState.Purging ? "purging" : "moving", item.Id, item.Path, index, plan.Items.Length));
            CleanupItemResult result;
            try
            {
                var completedEntries = execution.Items.Sum(result => result.RemovedEntries);
                var observed = await mutation.ApplyAsync(source.Workspace, item, plan.Action,
                    new InlineProgress<CleanupMutationProgress>(value => Report(progress, new(value.Phase, item.Id, value.Path, index, plan.Items.Length,
                        completedEntries + value.RemovedEntries, plan.Items.Sum(target => target.Manifest.Length)))),
                    plan.Action == CleanupAction.Permanent ? cancellationToken : CancellationToken.None);
                result = MutationResult(item, plan.Action, observed);
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            {
                // After durable intent an exception cannot prove that the native operation did nothing.
                result = new(item.Id, CleanupItemState.Unknown, Reason: "native_result_unknown");
            }
            execution = SetItem(execution, index, result);
            await SaveExecutionAsync(lease, execution, plan);
            Report(progress, new("recorded", item.Id, item.Path, index + 1, plan.Items.Length, execution.Items.Sum(result => result.RemovedEntries), plan.Items.Sum(target => target.Manifest.Length)));
            if (result.State == CleanupItemState.Unknown)
            {
                execution = StopRemaining(execution, index + 1, CleanupItemState.Skipped, "verification_required");
                break;
            }
            if (result.State == CleanupItemState.Cancelled)
            {
                execution = StopRemaining(execution, index + 1, CleanupItemState.Cancelled, "cancelled");
                break;
            }
        }
        var state = execution.Items.Any(item => item.State == CleanupItemState.Unknown) ? CleanupExecutionState.Unknown :
            execution.Items.All(item => item.State is CleanupItemState.Purged or CleanupItemState.Trashed) ? CleanupExecutionState.Completed :
            execution.Items.Any(item => item.State == CleanupItemState.Cancelled) && !execution.Items.Any(item => item.State == CleanupItemState.Failed) ? CleanupExecutionState.Cancelled : CleanupExecutionState.Partial;
        execution = execution with { State = state, UpdatedAt = Updated(execution) };
        await SaveExecutionAsync(lease, execution, plan);
        return execution;
    }

    private async Task<(ScanSnapshot Scan, RuleClassification Classification, FileTreeIndex Index)> ObserveAsync(Configuration configuration, Workspace workspace,
        CleanupRule[] rules, ValidationBudget budget, CancellationToken cancellationToken, IProgress<ScanProgress>? progress = null)
    {
        var scan = await scanner.ScanAsync(workspace.Path, budget.NextScan(), progress, cancellationToken);
        budget.Observe(scan);
        cancellationToken.ThrowIfCancellationRequested();
        if (scan.Root != workspace.Path || scan.RootIdentity != workspace.Identity ||
            scan.Entries.FirstOrDefault(entry => entry.Entry.Path == workspace.Path)?.Entry is not { Kind: EntryKind.Directory } root || root.IsCaseSensitive != workspace.CaseSensitive) throw Stale();
        var index = new FileTreeIndex(scan);
        return (scan, scans.Classify(configuration, workspace, rules, scan, budget.Remaining(), cancellationToken, index), index);
    }

    private static void VerifyItem(CleanupPlanItem item, (ScanSnapshot Scan, RuleClassification Classification, FileTreeIndex Index) current)
    {
        var candidate = FindCurrent(current.Classification, item.RuleId, item.Path);
        RequireCandidate(candidate);
        if (candidate.ManifestDigest != item.ManifestDigest) throw Stale();
        RequireContext(item.Context, current.Index);
    }

    private Workspace CurrentWorkspace(Configuration configuration, Workspace expected, string digest)
    {
        var current = configuration.Workspaces.FirstOrDefault(workspace => workspace.Id == expected.Id);
        if (current is null || configurationCodec.Digest(configuration) != digest || RecordJson.Digest(current) != RecordJson.Digest(expected) || current.Identity.OwnerSid != protection.OwnerSid) throw Stale();
        return current;
    }

    private static bool SameRules(ImmutableArray<ScanRule> source, CleanupRule[] rules) => source.Length == rules.Length &&
        source.All(record => rules.Any(rule => rule.Digest == record.Digest && rule.Id == record.Definition.GetProperty("id").GetString()));

    private void RequireBindings(Configuration configuration, CleanupPlan plan)
    {
        foreach (var source in plan.Sources)
        {
            var current = scans.EnabledRules(configuration, source.Workspace.Id);
            foreach (var rule in source.Rules)
                if (!current.Any(value => value.Digest == rule.Digest && value.Id == rule.Definition.GetProperty("id").GetString() &&
                    value.Version == rule.Definition.GetProperty("version").GetString())) throw Stale();
        }
    }

    private void RequireSources(Configuration configuration, CleanupPlan plan)
    {
        foreach (var source in plan.Sources) _ = CurrentWorkspace(configuration, source.Workspace, plan.ConfigurationDigest);
    }
    private static bool Overlap(WindowsPath first, WindowsPath second) => first.IsWithin(second) || second.IsWithin(first);
    private CleanupRule[] ParseRules(CleanupPlanSource source) => source.Rules.Select(rule => validator.Parse(Encoding.UTF8.GetBytes(rule.Definition.GetRawText()))).ToArray();
    private async Task<Configuration> ReadConfigurationAsync(IRecordLease lease, CancellationToken token) =>
        configurationCodec.Decode(await lease.ReadAsync("configuration", ConfigurationCodec.MaximumBytes, token));

    private async Task RequireIdleAsync(Workspace workspace, CleanupPlanItem item, CancellationToken token)
    {
        var observed = await activity.InspectAsync(workspace, item, token);
        if (observed.State != ActivityState.Idle) throw new ShouException(observed.State == ActivityState.Active ? "active_target" : "activity_unknown", "The current activity check does not permit cleanup of this target.");
    }

    private static RuleCandidate FindCurrent(RuleClassification classification, string ruleId, WindowsPath path) =>
        classification.Candidates.FirstOrDefault(candidate => candidate.RuleId == ruleId && candidate.Path == path) ?? throw Stale();
    private static void RequireCandidate(RuleCandidate candidate)
    {
        if (!candidate.Complete || candidate.State != "review" || candidate.BlockedReasons.Length != 0 || candidate.ManifestDigest is null) throw Stale();
    }

    private static ImmutableArray<FileEntry> Context(ScanSnapshot scan, FileTreeIndex index, WindowsPath target, CleanupRule rule)
    {
        var entries = index.Entries;
        var context = new List<FileEntry>();
        for (var parent = target.Parent!; ; parent = parent.Parent!)
        {
            if (!entries.TryGetValue(parent, out var entry)) throw Stale();
            context.Add(entry);
            if (parent == scan.Root) break;
        }
        var comparison = entries[target.Parent!].IsCaseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        foreach (var marker in rule.ParentMarkers)
            context.Add(entries.Values.Single(entry => entry.Path.Parent == target.Parent && string.Equals(entry.Path.Name, marker, comparison)));
        return context.DistinctBy(entry => entry.Path).OrderBy(entry => entry.Path.Value, StringComparer.Ordinal).ToImmutableArray();
    }

    private static void RequireContext(ImmutableArray<FileEntry> expected, FileTreeIndex current)
    {
        var entries = current.Entries;
        foreach (var entry in expected)
            if (!entries.TryGetValue(entry.Path, out var found) || (entry.Kind == EntryKind.Directory
                ? found.Kind != EntryKind.Directory || found.Identity != entry.Identity || found.IsCaseSensitive != entry.IsCaseSensitive
                : found != entry)) throw Stale();
    }

    private CleanupExecution SetItem(CleanupExecution execution, int index, CleanupItemResult result) =>
        execution with { Items = execution.Items.SetItem(index, result), UpdatedAt = Updated(execution) };
    private CleanupExecution StopRemaining(CleanupExecution execution, int start, CleanupItemState state, string reason) => execution with
    {
        Items = execution.Items.Select((item, index) => index >= start && item.State == CleanupItemState.Pending ? item with { State = state, Reason = reason } : item).ToImmutableArray(),
        UpdatedAt = Updated(execution)
    };
    private DateTimeOffset Updated(CleanupExecution execution) => new[] { execution.UpdatedAt, clock.GetUtcNow() }.Max();

    private async Task SaveExecutionAsync(IRecordLease lease, CleanupExecution execution, CleanupPlan plan)
    {
        try { await lease.WriteAsync(execution.Id, records.EncodeExecution(execution, plan), CancellationToken.None); }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        { throw new ShouException("journal_write_failed", "Execution stopped because its durable result could not be confirmed. Inspect the saved execution before taking further action.", error); }
    }

    private static CleanupItemResult MutationResult(CleanupPlanItem item, CleanupAction action, CleanupMutationResult result)
    {
        if (result is null || !Enum.IsDefined(result.Outcome) || result.RemovedEntries < 0 || result.RemovedEntries > item.Manifest.Length) return new(item.Id, CleanupItemState.Unknown, Reason: "invalid_native_result");
        var reason = ValidReason(result.Reason) ? result.Reason : "native_failure";
        if (result.Outcome == CleanupMutationOutcome.Completed)
        {
            if (action == CleanupAction.Permanent && result.RemovedEntries == item.Manifest.Length && result.ResultPath is null && result.ResultIdentity is null)
                return new(item.Id, CleanupItemState.Purged, result.RemovedEntries);
            if (action == CleanupAction.Trash && result.RemovedEntries == 0 && result.ResultPath is not null && result.ResultPath != item.Path && result.ResultIdentity == item.Manifest[0].Identity)
                return new(item.Id, CleanupItemState.Trashed, ResultPath: result.ResultPath, ResultIdentity: result.ResultIdentity);
            return new(item.Id, CleanupItemState.Unknown, result.RemovedEntries, "invalid_native_result");
        }
        if (result.ResultPath is not null || result.ResultIdentity is not null) return new(item.Id, CleanupItemState.Unknown, result.RemovedEntries, "invalid_native_result");
        return new(item.Id, result.Outcome switch { CleanupMutationOutcome.Failed => CleanupItemState.Failed, CleanupMutationOutcome.Cancelled => CleanupItemState.Cancelled, _ => CleanupItemState.Unknown },
            result.RemovedEntries, reason ?? "native_result_unknown");
    }

    private static bool ValidReason(string? reason) => reason is null || reason.Length is > 0 and <= 80 && reason.All(character => char.IsAsciiLetterLower(character) || character == '_');
    private static string Reason(Exception error) => error is ShouException known && ValidReason(known.Code) ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "read_failed";
    private sealed class ValidationBudget(ScanBudget budget, TimeProvider clock, long? start = null)
    {
        private readonly long started = start ?? clock.GetTimestamp();
        private int entries;
        public TimeSpan Remaining()
        {
            var remaining = budget.Duration - clock.GetElapsedTime(started);
            return remaining > TimeSpan.Zero ? remaining : throw new ShouException("time_limit", "Cleanup validation reached its shared time budget.");
        }
        public ScanBudget NextScan() => entries >= budget.MaxEntries ? throw new ShouException("entry_limit", "Cleanup validation reached its shared entry budget.") :
            budget with { MaxEntries = budget.MaxEntries - entries, MaxDuration = Remaining() };
        public void Observe(ScanSnapshot scan)
        {
            entries = checked(entries + scan.Entries.Length);
            if (entries > budget.MaxEntries) throw new ShouException("entry_limit", "Cleanup validation exceeded its shared entry budget.");
        }
    }
    private void RequireSupported(CleanupAction action)
    {
        if (!mutation.Supports(action)) throw new ShouException("unsupported_capability", "This cleanup action is unavailable on the current platform.");
    }
    private void RequireCurrentTime(CleanupPlan plan)
    {
        var now = clock.GetUtcNow();
        if (now < plan.CreatedAt || now >= plan.ExpiresAt) throw Stale();
    }
    private static void ValidatePlanId(string id) { if (!RecordKey.IsId(id, "plan")) throw Input("Choose a valid plan identifier."); }
    private sealed class InlineProgress<T>(Action<T> report) : IProgress<T> { public void Report(T value) => report(value); }
    private sealed class ThrottledProgress(IProgress<CleanupProgress> target, TimeProvider clock) : IProgress<CleanupProgress>
    {
        private CleanupProgress? previous;
        private long timestamp;
        public void Report(CleanupProgress value)
        {
            var now = clock.GetTimestamp();
            if (previous is { } before && before.Phase == value.Phase && before.ItemId == value.ItemId && before.ProcessedItems == value.ProcessedItems &&
                clock.GetElapsedTime(timestamp, now) < TimeSpan.FromMilliseconds(40) && value.Phase != "recorded") return;
            previous = value; timestamp = now;
            target.Report(value);
        }
    }
    private static void Report(IProgress<CleanupProgress>? progress, CleanupProgress value)
    {
        // Progress is advisory; a consumer failure cannot discard durable execution facts.
        try { progress?.Report(value); } catch (Exception error) when (error is not OutOfMemoryException) { }
    }
    private static ShouException Input(string message) => new("invalid_argument", message);
    private static ShouException Stale() => new("plan_stale", "Configuration, activity or filesystem evidence changed. Review and scan again.");
    private static ShouException Consumed() => new("plan_consumed", "This plan already has execution intent and cannot be replayed.");
}
