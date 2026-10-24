using System.Collections.Immutable;
using System.Text.Json;

namespace Shou.Windows.Core;

/// <summary>Explicit privacy scope and per-database execution, sharing the existing store and mutation lease.</summary>
public sealed class PrivacyCleanupService(IRecordStore store, RuleSchemaValidator validator, PrivacyScanService scans,
    IPrivacyDatabaseInspection databases, IPrivacyBrowserActivity activity, IPrivacyMutation mutation, string ownerSid, TimeProvider? timeProvider = null)
{
    public const int MaximumSelectedSources = 256;
    public const int MaximumPlanBytes = 8_388_608;
    public const int MaximumReceiptBytes = 131_072;
    public const int MaximumHistoryDirectoryEntries = 4096;
    public const int MaximumHistoryBytes = 33_554_432;
    public static readonly TimeSpan HistoryDuration = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan PlanLifetime = TimeSpan.FromMinutes(5);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly ConfigurationCodec configurations = new(validator);
    private readonly Guid issuer = Guid.NewGuid();

    public async Task<PrivacyPlan> CreatePlanAsync(string scanId, IEnumerable<string> sourceIds, bool acknowledgeSignOut = false, CancellationToken cancellationToken = default)
    {
        if (!RecordKey.IsId(scanId, "privacy_scan") || sourceIds is null) throw Input();
        var selected = sourceIds.Take(MaximumSelectedSources + 1).ToArray();
        if (selected.Length is 0 or > MaximumSelectedSources || selected.Any(id => !RecordKey.IsId(id, "privacy_source")) || selected.Distinct(StringComparer.Ordinal).Count() != selected.Length) throw Input();
        await using var lease = await store.AcquireLeaseAsync(cancellationToken).ConfigureAwait(false);
        var scan = await LoadScanAsync(lease, scanId, cancellationToken).ConfigureAwait(false);
        var sources = scan.Sources.Where(source => selected.Contains(source.Source.Id, StringComparer.Ordinal)).ToImmutableArray();
        if (sources.Length != selected.Length || sources.Any(source => source.State != PrivacySourceState.Ready || source.RecordCount is not > 0)) throw Input();
        if (!acknowledgeSignOut && sources.Any(source => source.Source.Kind == PrivacyDataKind.Cookies)) throw SignOutRequired();
        var now = clock.GetUtcNow();
        if (now < scan.CreatedAt || now >= scan.ExpiresAt) throw Stale();
        try { _ = sources.Sum(source => source.RecordCount!.Value); }
        catch (OverflowException) { throw new ShouException("resource_limit", "The privacy record total exceeds its accounting limit. Choose fewer sources."); }
        var plan = new PrivacyPlan(1, RecordKey.New("privacy_plan"), scan.Id, scan.Digest, ownerSid, now,
            new[] { scan.ExpiresAt, now + PlanLifetime }.Min(), scan.Window, scan.ConfigurationDigest, sources, acknowledgeSignOut, "");
        plan = plan with { Digest = PlanDigest(plan) };
        ValidatePlan(plan, plan.Id, scan);
        await PreflightAsync(lease, plan, cancellationToken).ConfigureAwait(false);
        if (await lease.ReadAsync(plan.Id, MaximumPlanBytes, cancellationToken).ConfigureAwait(false) is not null) throw new ShouException("version_conflict", "The privacy plan already exists.");
        await lease.WriteAsync(plan.Id, RecordJson.Encode(plan, MaximumPlanBytes), cancellationToken).ConfigureAwait(false);
        return plan;
    }

    public async Task<PrivacyPlan> ReadPlanAsync(string planId, CancellationToken cancellationToken = default)
    {
        _ = ReceiptId(planId);
        await using var lease = await store.AcquireReadLeaseAsync(cancellationToken).ConfigureAwait(false) ?? throw Missing();
        return await LoadPlanAsync(lease, planId, cancellationToken).ConfigureAwait(false);
    }

    public async Task<PrivacyConsent> ConfirmAsync(string planId, IPrivacyConfirmation confirmation, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(confirmation);
        _ = ReceiptId(planId); RequireAvailable();
        PrivacyPlan plan;
        await using (var lease = await store.AcquireReadLeaseAsync(cancellationToken).ConfigureAwait(false) ?? throw Missing())
        {
            plan = await LoadPlanAsync(lease, planId, cancellationToken).ConfigureAwait(false);
            RequireUnused(await lease.ReadAsync(ReceiptId(planId), MaximumReceiptBytes, cancellationToken).ConfigureAwait(false));
            await PreflightAsync(lease, plan, cancellationToken).ConfigureAwait(false);
        }
        // A user may inspect settings while the prompt is visible. Execution takes a fresh lease and rechecks them.
        var decision = await confirmation.RequestAsync(plan, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested(); RequireCurrent(plan);
        if (!decision.IrreversibleDeletion) throw ConfirmationRequired();
        if (RequiresSignOut(plan) && !decision.SignOut) throw SignOutRequired();
        return new(issuer, plan, clock.GetUtcNow());
    }

    public async Task<PrivacyReceipt> ExecuteAsync(string planId, PrivacyConsent? consent, CancellationToken cancellationToken = default)
    {
        var key = ReceiptId(planId); RequireAvailable();
        if (consent is null) throw ConfirmationRequired();
        await using var lease = await store.AcquireLeaseAsync(cancellationToken).ConfigureAwait(false);
        var plan = await LoadPlanAsync(lease, planId, cancellationToken).ConfigureAwait(false);
        RequireCurrent(plan); RequireUnused(await lease.ReadAsync(key, MaximumReceiptBytes, cancellationToken).ConfigureAwait(false));
        consent.Consume(issuer, plan, clock.GetUtcNow());
        await PreflightAsync(lease, plan, cancellationToken).ConfigureAwait(false);
        consent.RequireCurrent(clock.GetUtcNow()); cancellationToken.ThrowIfCancellationRequested();
        var now = clock.GetUtcNow();
        var receipt = new PrivacyReceipt(1, key, plan.Id, plan.Digest, plan.Window, now, now, PrivacyExecutionState.Executing,
            plan.Sources.Select(source => new PrivacyItemResult(source.Source.Id, PrivacyItemState.Pending, null, null)).ToImmutableArray(), "");
        receipt = await SaveAsync(lease, plan, receipt).ConfigureAwait(false);
        for (var index = 0; index < plan.Sources.Length; index++)
        {
            if (cancellationToken.IsCancellationRequested) { receipt = Stop(receipt, index, PrivacyItemState.Cancelled, "cancelled"); break; }
            var source = plan.Sources[index];
            try
            {
                RequireCurrent(plan);
                var configuration = await ConfigurationAsync(lease, plan, cancellationToken).ConfigureAwait(false);
                await VerifySourceAsync(plan, source, configuration, cancellationToken).ConfigureAwait(false);
                RequireCurrent(plan); cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            { receipt = Stop(receipt, index, PrivacyItemState.Cancelled, "cancelled"); break; }
            catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
            {
                receipt = Set(receipt, index, new(source.Source.Id, PrivacyItemState.Failed, 0, Reason(error)));
                receipt = Stop(receipt, index + 1, PrivacyItemState.Skipped, "preflight_failed"); break;
            }
            receipt = Set(receipt, index, new(source.Source.Id, PrivacyItemState.Executing, null, null));
            receipt = await SaveAsync(lease, plan, receipt).ConfigureAwait(false);
            PrivacyMutationResult result;
            try
            {
                result = cancellationToken.IsCancellationRequested ? new(PrivacyMutationOutcome.Cancelled, 0, "cancelled") :
                    await mutation.ApplyAsync(new(source, plan.Window, ownerSid, plan.ExpiresAt), cancellationToken).ConfigureAwait(false);
                if (!ValidResult(result, source.RecordCount!.Value)) result = new(PrivacyMutationOutcome.Unknown, Reason: "invalid_native_result");
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            { result = new(PrivacyMutationOutcome.Unknown, Reason: "native_result_unknown"); }
            receipt = Set(receipt, index, Result(source.Source.Id, result));
            receipt = await SaveAsync(lease, plan, receipt).ConfigureAwait(false);
            if (result.Outcome == PrivacyMutationOutcome.Unknown)
            { receipt = Stop(receipt, index + 1, PrivacyItemState.Skipped, "previous_outcome_unknown"); break; }
            if (result.Outcome == PrivacyMutationOutcome.Cancelled || cancellationToken.IsCancellationRequested)
            { receipt = Stop(receipt, index + 1, PrivacyItemState.Cancelled, "cancelled"); break; }
        }
        receipt = receipt with { State = receipt.Items.All(item => item.State == PrivacyItemState.Completed) ? PrivacyExecutionState.Completed : PrivacyExecutionState.Partial };
        return await SaveAsync(lease, plan, receipt).ConfigureAwait(false);
    }

    public async Task<PrivacyReceipt> ReadReceiptAsync(string planId, CancellationToken cancellationToken = default)
    {
        var key = ReceiptId(planId);
        await using var lease = await store.AcquireReadLeaseAsync(cancellationToken).ConfigureAwait(false) ?? throw Missing();
        var plan = await LoadPlanAsync(lease, planId, cancellationToken).ConfigureAwait(false);
        var bytes = await lease.ReadAsync(key, MaximumReceiptBytes, cancellationToken).ConfigureAwait(false) ?? throw Missing();
        return DecodeReceipt(bytes, plan);
    }

    /// <summary>Read-only, bounded and fully validated history; reading never renews execution authority.</summary>
    public async Task<ImmutableArray<PrivacyReceipt>> HistoryAsync(int limit = 20, CancellationToken cancellationToken = default)
    {
        if (limit is < 1 or > 100) throw Input();
        using var deadline = new CancellationTokenSource(HistoryDuration, clock);
        using var stopped = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        try
        {
            var token = stopped.Token;
            await using var lease = await store.AcquireReadLeaseAsync(token).ConfigureAwait(false);
            if (lease is null) return [];
            var keys = await lease.ListKeysAsync("privacy_receipt", MaximumHistoryDirectoryEntries, token).ConfigureAwait(false);
            var receipts = new List<PrivacyReceipt>();
            long totalBytes = 0;
            async Task<byte[]> Read(string key, int maximum)
            {
                token.ThrowIfCancellationRequested();
                var bytes = await lease.ReadAsync(key, maximum, token).ConfigureAwait(false) ?? throw Missing();
                totalBytes += bytes.Length;
                if (totalBytes > MaximumHistoryBytes) throw new ShouException("resource_limit", "Privacy history exceeds its read budget. No partial history is presented as complete.");
                return bytes;
            }
            foreach (var key in keys)
            {
                if (!RecordKey.IsId(key, "privacy_receipt")) throw Corrupt();
                var planId = "privacy_plan_" + key["privacy_receipt_".Length..];
                var plan = DecodePlan(await Read(planId, MaximumPlanBytes).ConfigureAwait(false), planId);
                var scan = scans.Decode(await Read(plan.ScanId, PrivacyScanService.MaximumScanBytes).ConfigureAwait(false), plan.ScanId);
                ValidatePlan(plan, planId, scan);
                receipts.Add(DecodeReceipt(await Read(key, MaximumReceiptBytes).ConfigureAwait(false), plan));
            }
            token.ThrowIfCancellationRequested();
            return receipts.OrderByDescending(receipt => receipt.StartedAt).ThenBy(receipt => receipt.Id, StringComparer.Ordinal).Take(limit).ToImmutableArray();
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && deadline.IsCancellationRequested)
        { throw new ShouException("time_limit", "Privacy history could not be read within ten seconds."); }
    }

    private static PrivacyReceipt DecodeReceipt(byte[] bytes, PrivacyPlan plan)
    {
        try
        {
            if (bytes.Length > MaximumReceiptBytes) throw Corrupt();
            var receipt = JsonSerializer.Deserialize<PrivacyReceipt>(bytes, ContractJson.Options) ?? throw Corrupt();
            ValidateReceipt(receipt, plan); return receipt;
        }
        catch (Exception error) when (error is JsonException or ShouException or ArgumentException or NullReferenceException or InvalidOperationException or OverflowException)
        { throw Corrupt(); }
    }

    public static string ReceiptId(string planId) => RecordKey.IsId(planId, "privacy_plan") ? "privacy_receipt_" + planId["privacy_plan_".Length..] : throw Input();
    public static bool RequiresSignOut(PrivacyPlan plan) => plan.Sources.Any(source => source.Source.Kind == PrivacyDataKind.Cookies);

    private async Task<PrivacyScan> LoadScanAsync(IRecordReadLease lease, string scanId, CancellationToken token) =>
        scans.Decode(await lease.ReadAsync(scanId, PrivacyScanService.MaximumScanBytes, token).ConfigureAwait(false) ?? throw Missing(), scanId);
    private async Task<PrivacyPlan> LoadPlanAsync(IRecordReadLease lease, string planId, CancellationToken token)
    {
        var bytes = await lease.ReadAsync(planId, MaximumPlanBytes, token).ConfigureAwait(false) ?? throw Missing();
        var plan = DecodePlan(bytes, planId);
        var scan = await LoadScanAsync(lease, plan.ScanId, token).ConfigureAwait(false);
        ValidatePlan(plan, planId, scan); return plan;
    }
    private PrivacyPlan DecodePlan(byte[] bytes, string planId)
    {
        PrivacyPlan plan;
        try
        {
            if (bytes.Length > MaximumPlanBytes) throw Corrupt();
            plan = JsonSerializer.Deserialize<PrivacyPlan>(bytes, ContractJson.Options) ?? throw Corrupt();
            ValidateShape(plan, planId);
        }
        catch (Exception error) when (error is JsonException or ShouException or ArgumentException or NullReferenceException or InvalidOperationException or OverflowException)
        { throw Corrupt(); }
        return plan;
    }
    private async Task PreflightAsync(IRecordReadLease lease, PrivacyPlan plan, CancellationToken token)
    {
        RequireCurrent(plan);
        using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(2), clock);
        using var stopped = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
        try
        {
            var configuration = await ConfigurationAsync(lease, plan, stopped.Token).ConfigureAwait(false);
            foreach (var source in plan.Sources) await VerifySourceAsync(plan, source, configuration, stopped.Token).ConfigureAwait(false);
            stopped.Token.ThrowIfCancellationRequested(); RequireCurrent(plan);
            _ = await ConfigurationAsync(lease, plan, stopped.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new ShouException("time_limit", "Privacy verification reached its budget. No privacy execution intent was created."); }
    }
    private async Task<Configuration> ConfigurationAsync(IRecordReadLease lease, PrivacyPlan plan, CancellationToken token)
    {
        var configuration = configurations.Decode(await lease.ReadAsync("configuration", ConfigurationCodec.MaximumBytes, token).ConfigureAwait(false));
        if (configurations.Digest(configuration) != plan.ConfigurationDigest) throw Stale();
        return configuration;
    }
    private async Task VerifySourceAsync(PrivacyPlan plan, PrivacySourceObservation source, Configuration configuration, CancellationToken token)
    {
        scans.RequireAllowed(source.Source, configuration);
        await RequireIdleAsync(source.Source.Browser, token).ConfigureAwait(false);
        var observed = await databases.InspectAsync(source.Source, plan.Window, token).ConfigureAwait(false);
        scans.ValidateObservation(source.Source, observed);
        if (source.RecordCount != observed.RecordCount || source.SchemaDigest != observed.SchemaDigest || !source.Evidence.SequenceEqual(observed.Evidence)) throw Stale();
        await RequireIdleAsync(source.Source.Browser, token).ConfigureAwait(false);
    }
    private async Task RequireIdleAsync(PrivacyBrowser browser, CancellationToken token)
    {
        var observed = await activity.InspectAsync(browser, token).ConfigureAwait(false);
        if (observed is null || observed.State != ActivityState.Idle)
            throw new ShouException(observed?.State == ActivityState.Active ? "privacy_browser_running" : "privacy_activity_unknown", "Close the browser and verify its activity before privacy cleaning.");
    }
    private void ValidateShape(PrivacyPlan plan, string id)
    {
        if (plan.Version != 1 || plan.Id != id || !RecordKey.IsId(id, "privacy_plan") || !RecordKey.IsId(plan.ScanId, "privacy_scan") ||
            !RecordJson.IsDigest(plan.ScanDigest) || plan.OwnerSid != ownerSid || plan.CreatedAt.Offset != TimeSpan.Zero || plan.ExpiresAt.Offset != TimeSpan.Zero ||
            plan.ExpiresAt <= plan.CreatedAt || plan.ExpiresAt - plan.CreatedAt > PlanLifetime || plan.Window is null || plan.Window.End > plan.CreatedAt ||
            !RecordJson.IsDigest(plan.ConfigurationDigest) || plan.Sources.IsDefaultOrEmpty || plan.Sources.Length > MaximumSelectedSources ||
            plan.Sources.Any(source => source?.Source is null || source.State != PrivacySourceState.Ready || source.RecordCount is not > 0 || source.Reason is not null) ||
            plan.Sources.Select(source => source.Source.Id).Distinct(StringComparer.Ordinal).Count() != plan.Sources.Length ||
            plan.Sources.Select(source => source.Source.Path.Value).Distinct(StringComparer.OrdinalIgnoreCase).Count() != plan.Sources.Length ||
            RequiresSignOut(plan) && !plan.SignOutAcknowledged || !RecordJson.IsDigest(plan.Digest) || PlanDigest(plan) != plan.Digest) throw Corrupt();
        plan.Window.Validate();
        var identities = new HashSet<FileIdentity>();
        long total = 0;
        foreach (var source in plan.Sources)
        {
            scans.ValidateObservation(source.Source, new(source.RecordCount!.Value, source.SchemaDigest!, source.Evidence));
            if (!identities.Add(source.Evidence.Single(item => item.Entry.Path == source.Source.Path).Entry.Identity)) throw Corrupt();
            total = checked(total + source.RecordCount.Value);
        }
    }
    private void ValidatePlan(PrivacyPlan plan, string id, PrivacyScan scan)
    {
        ValidateShape(plan, id);
        if (plan.ScanDigest != scan.Digest || plan.ScanId != scan.Id || plan.Window != scan.Window || plan.ConfigurationDigest != scan.ConfigurationDigest ||
            plan.CreatedAt < scan.CreatedAt || plan.ExpiresAt != new[] { scan.ExpiresAt, plan.CreatedAt + PlanLifetime }.Min() ||
            !plan.Sources.Select(source => source.Source.Id).SequenceEqual(scan.Sources.Where(source => plan.Sources.Any(selected => selected.Source.Id == source.Source.Id)).Select(source => source.Source.Id)) ||
            plan.Sources.Any(source => scan.Sources.SingleOrDefault(original => original.Source.Id == source.Source.Id) is not { } original ||
                RecordJson.Digest(source) != RecordJson.Digest(original))) throw Corrupt();
    }
    private void RequireCurrent(PrivacyPlan plan)
    { var now = clock.GetUtcNow(); if (now < plan.CreatedAt || now >= plan.ExpiresAt) throw Stale(); }
    private void RequireAvailable()
    { if (!mutation.Available) throw new ShouException("unsupported_capability", "Privacy record deletion awaits native Windows acceptance."); }
    private static void RequireUnused(byte[]? bytes)
    { if (bytes is not null) throw new ShouException("plan_consumed", "This privacy plan has a durable execution intent and cannot be replayed. Read its receipt."); }
    private static string PlanDigest(PrivacyPlan plan) => RecordJson.Digest(plan with { Digest = "" });
    private static PrivacyReceipt Set(PrivacyReceipt receipt, int index, PrivacyItemResult result) => receipt with { Items = receipt.Items.SetItem(index, result) };
    private static PrivacyReceipt Stop(PrivacyReceipt receipt, int start, PrivacyItemState state, string reason) => receipt with
    { Items = receipt.Items.Select((item, index) => index >= start ? new(item.SourceId, state, 0, reason) : item).ToImmutableArray() };
    private async Task<PrivacyReceipt> SaveAsync(IRecordLease lease, PrivacyPlan plan, PrivacyReceipt receipt)
    {
        receipt = receipt with { UpdatedAt = new[] { receipt.UpdatedAt, clock.GetUtcNow() }.Max(), Digest = "" };
        receipt = receipt with { Digest = RecordJson.Digest(receipt) }; ValidateReceipt(receipt, plan);
        try { await lease.WriteAsync(receipt.Id, RecordJson.Encode(receipt, MaximumReceiptBytes), CancellationToken.None).ConfigureAwait(false); }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        { throw new ShouException("journal_write_failed", "Privacy intent or outcome publication could not be confirmed. Read the plan-bound receipt before taking further action.", error); }
        return receipt;
    }
    private static void ValidateReceipt(PrivacyReceipt receipt, PrivacyPlan plan)
    {
        if (receipt.Version != 1 || receipt.Id != ReceiptId(plan.Id) || receipt.PlanId != plan.Id || receipt.PlanDigest != plan.Digest ||
            receipt.Window != plan.Window || receipt.StartedAt.Offset != TimeSpan.Zero || receipt.UpdatedAt.Offset != TimeSpan.Zero ||
            receipt.StartedAt < plan.CreatedAt || receipt.StartedAt >= plan.ExpiresAt || receipt.UpdatedAt < receipt.StartedAt || !Enum.IsDefined(receipt.State) ||
            receipt.Items.IsDefault || receipt.Items.Length != plan.Sources.Length || !RecordJson.IsDigest(receipt.Digest) || RecordJson.Digest(receipt with { Digest = "" }) != receipt.Digest) throw Corrupt();
        var unfinishedSuffix = false;
        for (var index = 0; index < receipt.Items.Length; index++)
        {
            var item = receipt.Items[index];
            if (item is null || item.SourceId != plan.Sources[index].Source.Id || !Enum.IsDefined(item.State)) throw Corrupt();
            var valid = item.State switch
            {
                PrivacyItemState.Pending or PrivacyItemState.Executing => item.RemovedRecords is null && item.Reason is null && receipt.State == PrivacyExecutionState.Executing,
                PrivacyItemState.Completed => item.RemovedRecords == plan.Sources[index].RecordCount && item.Reason is null,
                PrivacyItemState.Unknown => item.RemovedRecords is null && SafeReason(item.Reason),
                _ => item.RemovedRecords == 0 && SafeReason(item.Reason)
            };
            if (!valid) throw Corrupt();
            if (unfinishedSuffix && item.State != PrivacyItemState.Pending) throw Corrupt();
            if (item.State is PrivacyItemState.Pending or PrivacyItemState.Executing) unfinishedSuffix = true;
        }
        var allCompleted = receipt.Items.All(item => item.State == PrivacyItemState.Completed);
        if (receipt.Items.Count(item => item.State == PrivacyItemState.Executing) > 1 ||
            receipt.State == PrivacyExecutionState.Completed && !allCompleted ||
            receipt.State == PrivacyExecutionState.Partial && (allCompleted || receipt.Items.Any(item => item.State is PrivacyItemState.Pending or PrivacyItemState.Executing))) throw Corrupt();
    }
    private static bool ValidResult(PrivacyMutationResult? result, long expected) => result is not null && Enum.IsDefined(result.Outcome) && (result.Outcome switch
    {
        PrivacyMutationOutcome.Completed => result.RemovedRecords == expected && result.Reason is null,
        PrivacyMutationOutcome.Unknown => result.RemovedRecords is null && (result.Reason is null || SafeReason(result.Reason)),
        _ => result.RemovedRecords == 0 && SafeReason(result.Reason)
    });
    private static PrivacyItemResult Result(string id, PrivacyMutationResult result) => new(id, result.Outcome switch
    {
        PrivacyMutationOutcome.Completed => PrivacyItemState.Completed, PrivacyMutationOutcome.Cancelled => PrivacyItemState.Cancelled,
        PrivacyMutationOutcome.Unknown => PrivacyItemState.Unknown, _ => PrivacyItemState.Failed
    }, result.RemovedRecords, result.Outcome == PrivacyMutationOutcome.Unknown ? result.Reason ?? "native_result_unknown" : result.Reason);
    private static bool SafeReason(string? value) => value is "cancelled" or "plan_stale" or "privacy_excluded" or "privacy_browser_running" or "privacy_activity_unknown" or
        "privacy_schema_unsupported" or "privacy_database_busy" or "privacy_query_limit" or "privacy_identity_unavailable" or "source_changed" or "privacy_database_unavailable" or
        "permission_denied" or "read_failed" or "preflight_failed" or "previous_outcome_unknown" or "invalid_native_result" or "native_result_unknown" or "unsupported_capability";
    private static string Reason(Exception error) => error is ShouException known && SafeReason(known.Code) ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "read_failed";
    private static ShouException Input() => new("invalid_argument", "Select distinct, ready privacy source IDs from one current scan.");
    private static ShouException Stale() => new("plan_stale", "The privacy scope, evidence, settings or time changed. Scan again.");
    private static ShouException Missing() => new("not_found", "The privacy scan, plan or receipt does not exist.");
    private static ShouException Corrupt() => new("store_corrupt", "The privacy plan or receipt metadata is invalid or inconsistent. It was not executed or replayed.");
    private static ShouException SignOutRequired() => new("privacy_sign_out_consent_required", "Cookie deletion can sign you out. Explicitly acknowledge this impact.");
    private static ShouException ConfirmationRequired() => new("confirmation_required", "Confirm permanent deletion for this exact current privacy plan.");
}
