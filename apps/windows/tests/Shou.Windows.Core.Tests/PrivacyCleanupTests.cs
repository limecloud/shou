using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class PrivacyCleanupTests
{
    private sealed class Confirmation(PrivacyConfirmationDecision? decision = null) : IPrivacyConfirmation
    {
        public PrivacyPlan? Plan;
        public Func<Task>? DuringPrompt;
        public async Task<PrivacyConfirmationDecision> RequestAsync(PrivacyPlan plan, CancellationToken token)
        { Plan = plan; if (DuringPrompt is not null) await DuringPrompt(); return decision ?? new(true, true); }
    }
    private sealed class Mutation(PrivacyScanTests.Fixture source) : IPrivacyMutation
    {
        public bool Available { get; set; } = true;
        public List<PrivacyMutationRequest> Requests = [];
        public Func<PrivacyMutationRequest, CancellationToken, Task<PrivacyMutationResult>>? Apply;
        public Task<PrivacyMutationResult> ApplyAsync(PrivacyMutationRequest request, CancellationToken token)
        {
            Requests.Add(request);
            var receipt = source.Store.Records.Where(pair => pair.Key.StartsWith("privacy_receipt_", StringComparison.Ordinal))
                .Select(pair => JsonSerializer.Deserialize<PrivacyReceipt>(pair.Value, ContractJson.Options)!)
                .Single(value => value.State == PrivacyExecutionState.Executing);
            Assert.Equal(PrivacyExecutionState.Executing, receipt.State);
            Assert.Equal(PrivacyItemState.Executing, receipt.Items.Single(item => item.SourceId == request.Source.Source.Id).State);
            return Apply?.Invoke(request, token) ?? Task.FromResult(new PrivacyMutationResult(PrivacyMutationOutcome.Completed, request.Source.RecordCount));
        }
    }
    private sealed class Fixture
    {
        public PrivacyScanTests.Fixture Source = new();
        public Mutation Mutation;
        public PrivacyCleanupService Service;
        public Fixture() { Mutation = new(Source); Service = MakeService(); }
        public PrivacyCleanupService MakeService(TimeProvider? clock = null, IRecordStore? store = null) => new(store ?? Source.Store, Source.Validator, Source.Service, Source, Source, Mutation, "S-1-5-21-1000", clock ?? Source.Clock);
        public async Task<PrivacyPlan> Plan(int sources = 1, bool cookies = false)
        {
            for (var index = 0; index < sources; index++) Source.Add(profile: index == 0 ? "Default" : "Profile " + index,
                location: cookies ? PrivacyDatabaseLocation.NetworkCookies : PrivacyDatabaseLocation.History);
            var scan = await Source.Service.ScanAsync();
            return await Service.CreatePlanAsync(scan.Id, scan.Sources.Select(item => item.Source.Id), cookies);
        }
        public async Task<PrivacyConsent> Confirm(PrivacyPlan plan) => await Service.ConfirmAsync(plan.Id, new Confirmation());
    }

    private sealed class HistoryReadStore(IRecordStore? inner = null, Action? beforeRead = null) : IRecordStore
    {
        public Task<IRecordReadLease?> AcquireReadLeaseAsync(CancellationToken token)
        { beforeRead?.Invoke(); token.ThrowIfCancellationRequested(); return inner?.AcquireReadLeaseAsync(token) ?? Task.FromResult<IRecordReadLease?>(null); }
        public ValueTask<byte[]?> ReadAsync(string key, int maximumBytes, CancellationToken token) => throw new InvalidOperationException("History must use its read lease.");
        public Task<T> UpdateAsync<T>(Func<IRecordTransaction, T> update, CancellationToken token) => throw new InvalidOperationException("History must not write.");
        public Task<IRecordLease> AcquireLeaseAsync(CancellationToken token) => throw new InvalidOperationException("History must not acquire a mutation lease.");
    }

    [Fact]
    public async Task HistoryWithoutADataRootIsEmptyAndNeverCreatesOne()
    {
        var f = new Fixture(); Assert.Empty(await f.MakeService(store: new HistoryReadStore()).HistoryAsync());
        Assert.Empty(f.Mutation.Requests); Assert.Empty(f.Source.Store.Records);
    }
    [Fact]
    public async Task HistoryIgnoresPlansWithoutExecutionIntentAndNeverWrites()
    {
        var f = new Fixture(); _ = await f.Plan(); var writes = f.Source.Store.Writes;
        Assert.Empty(await f.MakeService(store: new HistoryReadStore(f.Source.Store)).HistoryAsync());
        Assert.Equal(writes, f.Source.Store.Writes); Assert.Empty(f.Mutation.Requests);
    }
    [Fact]
    public async Task HistoryReturnsNewestReceiptsWithALimitEvenAfterPlanExpiryAndCannotRenewConsent()
    {
        var f = new Fixture(); var plan = await f.Plan();
        var first = await f.Service.ExecuteAsync(plan.Id, await f.Confirm(plan));
        f.Source.Clock.Now = f.Source.Clock.Now.AddSeconds(1);
        var next = await f.Service.CreatePlanAsync(plan.ScanId, plan.Sources.Select(source => source.Source.Id));
        var last = await f.Service.ExecuteAsync(next.Id, await f.Confirm(next));
        f.Source.Clock.Now = next.ExpiresAt.AddDays(1); var writes = f.Source.Store.Writes;
        var history = await f.MakeService(store: new HistoryReadStore(f.Source.Store)).HistoryAsync();
        Assert.Equal(new[] { last.Id, first.Id }, history.Select(receipt => receipt.Id));
        Assert.Equal(last.Id, Assert.Single(await f.Service.HistoryAsync(1)).Id);
        Assert.Equal(writes, f.Source.Store.Writes); Assert.Equal(2, f.Mutation.Requests.Count);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ConfirmAsync(last.PlanId, new Confirmation()))).Code);
    }
    [Theory]
    [InlineData("receipt")]
    [InlineData("plan")]
    [InlineData("scan")]
    public async Task HistoryRejectsCorruptEvidenceRatherThanReportingAnEmptyHistory(string kind)
    {
        var f = new Fixture(); var plan = await f.Plan(); var receipt = await f.Service.ExecuteAsync(plan.Id, await f.Confirm(plan));
        var key = kind switch { "receipt" => receipt.Id, "plan" => plan.Id, _ => plan.ScanId };
        f.Source.Store.Records[key] = "{}"u8.ToArray();
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => f.Service.HistoryAsync())).Code);
        Assert.Single(f.Mutation.Requests);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task HistoryRejectsMissingPlanOrScan(bool scan)
    {
        var f = new Fixture(); var plan = await f.Plan(); _ = await f.Service.ExecuteAsync(plan.Id, await f.Confirm(plan));
        f.Source.Store.Records.Remove(scan ? plan.ScanId : plan.Id);
        Assert.Equal("not_found", (await Assert.ThrowsAsync<ShouException>(() => f.Service.HistoryAsync())).Code);
    }
    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(101)]
    public async Task HistoryValidatesItsRequestedLimit(int limit)
    {
        var f = new Fixture(); Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => f.Service.HistoryAsync(limit))).Code);
    }
    [Fact]
    public async Task HistoryRejectsMalformedReceiptKeys()
    {
        var f = new Fixture(); f.Source.Store.Records["privacy_receipt_bad"] = "{}"u8.ToArray();
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => f.Service.HistoryAsync())).Code);
    }
    [Fact]
    public async Task HistoryAppliesItsTotalByteBudgetToPlansAndScansAsWellAsReceipts()
    {
        var f = new Fixture(); var plan = await f.Plan();
        for (var index = 0; index < 3; index++)
        {
            if (index > 0) plan = await f.Service.CreatePlanAsync(plan.ScanId, plan.Sources.Select(source => source.Source.Id));
            _ = await f.Service.ExecuteAsync(plan.Id, await f.Confirm(plan));
            var bytes = f.Source.Store.Records[plan.Id];
            var padded = new byte[PrivacyCleanupService.MaximumPlanBytes]; Array.Fill(padded, (byte)' '); bytes.CopyTo(padded, 0);
            f.Source.Store.Records[plan.Id] = padded;
        }
        var scanBytes = f.Source.Store.Records[plan.ScanId];
        var paddedScan = new byte[PrivacyCleanupService.MaximumPlanBytes];
        Array.Fill(paddedScan, (byte)' '); scanBytes.CopyTo(paddedScan, 0); f.Source.Store.Records[plan.ScanId] = paddedScan;
        var writes = f.Source.Store.Writes;
        Assert.Equal("resource_limit", (await Assert.ThrowsAsync<ShouException>(() => f.Service.HistoryAsync())).Code);
        Assert.Equal(writes, f.Source.Store.Writes);
    }
    [Fact]
    public async Task HistoryPropagatesCallerCancellationAndMapsOnlyItsOwnDeadline()
    {
        var f = new Fixture(); using var stop = new CancellationTokenSource(); stop.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Service.HistoryAsync(cancellationToken: stop.Token));
        var clock = new ManualDeadlineClock();
        var service = f.MakeService(clock, new HistoryReadStore(beforeRead: clock.Expire));
        Assert.Equal("time_limit", (await Assert.ThrowsAsync<ShouException>(() => service.HistoryAsync())).Code);
        Assert.Empty(f.Mutation.Requests);
    }

    [Fact]
    public async Task ExactSelectionFixesRangeEvidenceAndDigestWithoutMutatingOrConfirming()
    {
        var f = new Fixture(); var one = f.Source.Add(); f.Source.Add(PrivacyBrowser.Edge);
        var scan = await f.Source.Service.ScanAsync(); var before = f.Source.Files.Entries.ToArray();
        var plan = await f.Service.CreatePlanAsync(scan.Id, [one.Id]);
        Assert.Equal(scan.Digest, plan.ScanDigest); Assert.Equal(scan.Window, plan.Window); Assert.Equal(scan.ConfigurationDigest, plan.ConfigurationDigest);
        Assert.Equal(one, Assert.Single(plan.Sources).Source); Assert.Equal(TimeSpan.FromMinutes(5), plan.ExpiresAt - plan.CreatedAt);
        Assert.Equal(plan.Digest, (await f.Service.ReadPlanAsync(plan.Id)).Digest); Assert.Empty(f.Mutation.Requests); Assert.Equal(before, f.Source.Files.Entries.ToArray());
        Assert.DoesNotContain(f.Source.Store.Records, pair => pair.Key.StartsWith("privacy_receipt_", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("none")]
    [InlineData("duplicate")]
    [InlineData("foreign")]
    [InlineData("too_many")]
    [InlineData("empty")]
    [InlineData("running")]
    public async Task PlanRejectsInvalidOrUnavailableSelections(string kind)
    {
        var f = new Fixture(); var source = f.Source.Add();
        if (kind == "empty") f.Source.Count = 0;
        if (kind == "running") f.Source.Activity = ActivityState.Active;
        var scan = await f.Source.Service.ScanAsync();
        var ids = kind switch
        {
            "none" => Array.Empty<string>(), "duplicate" => [source.Id, source.Id], "foreign" => [RecordKey.New("privacy_source")],
            "too_many" => Enumerable.Range(0, 257).Select(_ => RecordKey.New("privacy_source")).ToArray(), _ => [source.Id]
        };
        Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => f.Service.CreatePlanAsync(scan.Id, ids))).Code);
        Assert.DoesNotContain(f.Source.Store.Records, pair => pair.Key.StartsWith("privacy_plan_", StringComparison.Ordinal)); Assert.Empty(f.Mutation.Requests);
    }

    [Fact]
    public async Task ReadySelectionFromPartialScanDoesNotAuthorizeUnselectedUnavailableSources()
    {
        var f = new Fixture(); var ready = f.Source.Add(); var blocked = f.Source.Add(PrivacyBrowser.Edge);
        f.Source.Files.Entries[blocked.Path.Value] = f.Source.Files.Entries[blocked.Path.Value] with { LinkCount = 2 };
        var scan = await f.Source.Service.ScanAsync(); Assert.False(scan.Complete);
        var plan = await f.Service.CreatePlanAsync(scan.Id, [ready.Id]); Assert.Single(plan.Sources);
        var receipt = await f.Service.ExecuteAsync(plan.Id, await f.Confirm(plan)); Assert.Single(receipt.Items); Assert.Single(f.Mutation.Requests);
    }

    [Fact]
    public async Task CookieImpactAcknowledgementCannotReplaceCurrentExecutionConsent()
    {
        var f = new Fixture(); var cookie = f.Source.Add(location: PrivacyDatabaseLocation.NetworkCookies); var scan = await f.Source.Service.ScanAsync();
        Assert.Equal("privacy_sign_out_consent_required", (await Assert.ThrowsAsync<ShouException>(() => f.Service.CreatePlanAsync(scan.Id, [cookie.Id]))).Code);
        var plan = await f.Service.CreatePlanAsync(scan.Id, [cookie.Id], true); Assert.True(plan.SignOutAcknowledged);
        Assert.Equal("privacy_sign_out_consent_required", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ConfirmAsync(plan.Id, new Confirmation(new(true, false))))).Code);
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(plan.Id, null))).Code);
        Assert.Empty(f.Mutation.Requests);
        var result = await f.Service.ExecuteAsync(plan.Id, await f.Confirm(plan)); Assert.Equal(PrivacyExecutionState.Completed, result.State);
    }

    [Fact]
    public async Task GateBlocksConfirmationAndExecutionWithoutPromptOrNativeAccess()
    {
        var f = new Fixture(); var plan = await f.Plan(); var consent = await f.Confirm(plan);
        f.Mutation.Available = false; var prompt = new Confirmation(); var reads = f.Source.DatabaseCalls;
        Assert.Equal("unsupported_capability", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ConfirmAsync(plan.Id, prompt))).Code);
        Assert.Null(prompt.Plan); Assert.Equal(reads, f.Source.DatabaseCalls);
        Assert.Equal("unsupported_capability", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(plan.Id, consent))).Code); Assert.Empty(f.Mutation.Requests);
    }

    [Fact]
    public async Task DeclineDoesNotConsumePlanButDoesNotGrantConsent()
    {
        var f = new Fixture(); var plan = await f.Plan(); var prompt = new Confirmation(new(false, false));
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ConfirmAsync(plan.Id, prompt))).Code);
        Assert.Equal(plan.Digest, prompt.Plan!.Digest); Assert.Empty(f.Mutation.Requests);
        Assert.Equal(PrivacyExecutionState.Completed, (await f.Service.ExecuteAsync(plan.Id, await f.Confirm(plan))).State);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PromptReleasesStoreLeaseAndCannotKeepExpiredOrChangedSettingsCurrent(bool expire)
    {
        var f = new Fixture(); var plan = await f.Plan();
        var prompt = new Confirmation { DuringPrompt = async () =>
        {
            _ = await f.Source.Store.ReadAsync("configuration", ConfigurationCodec.MaximumBytes, default);
            if (expire) f.Source.Clock.Now = plan.ExpiresAt; else f.Source.Configure(["**/History"]);
        } };
        if (expire) Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ConfirmAsync(plan.Id, prompt))).Code);
        else
        {
            var consent = await f.Service.ConfirmAsync(plan.Id, prompt);
            Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(plan.Id, consent))).Code);
        }
        Assert.Empty(f.Mutation.Requests); Assert.DoesNotContain(f.Source.Store.Records, pair => pair.Key.StartsWith("privacy_receipt_", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("count")]
    [InlineData("identity")]
    [InlineData("schema")]
    [InlineData("activity")]
    [InlineData("configuration")]
    public async Task ChangedEvidenceBeforeConfirmationOrExecutionNeverWritesIntent(string change)
    {
        foreach (var afterConfirm in new[] { false, true })
        {
            var f = new Fixture(); var plan = await f.Plan(2); var consent = afterConfirm ? await f.Confirm(plan) : null;
            switch (change)
            {
                case "count": f.Source.Count++; break;
                case "identity":
                    var path = plan.Sources[1].Source.Path.Value; var entry = f.Source.Files.Entries[path];
                    f.Source.Files.Entries[path] = entry with { Identity = new(1, new string('f', 32), entry.Identity.OwnerSid) }; break;
                case "schema": f.Source.Alter = observation => observation with { SchemaDigest = "sha256:" + new string('b', 64) }; break;
                case "activity": f.Source.Activity = ActivityState.Active; break;
                default: f.Source.Configure(["**/History"]); break;
            }
            var error = await Assert.ThrowsAsync<ShouException>(() => afterConfirm ? f.Service.ExecuteAsync(plan.Id, consent) : Confirm(f.Service, plan.Id));
            Assert.Contains(error.Code, new[] { "plan_stale", "privacy_browser_running" }); Assert.Empty(f.Mutation.Requests);
            Assert.DoesNotContain(f.Source.Store.Records, pair => pair.Key.StartsWith("privacy_receipt_", StringComparison.Ordinal));
        }
    }
    private static async Task<PrivacyReceipt> Confirm(PrivacyCleanupService service, string id)
    { await service.ConfirmAsync(id, new Confirmation()); throw new InvalidOperationException("Confirmation should fail."); }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ScanLifetimeBoundsPlansAndExpiredScansCannotPrepare(bool expired)
    {
        var f = new Fixture(); var source = f.Source.Add(); var scan = await f.Source.Service.ScanAsync(); f.Source.Clock.Now = scan.CreatedAt.AddMinutes(expired ? 15 : 14);
        if (expired) Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => f.Service.CreatePlanAsync(scan.Id, [source.Id]))).Code);
        else { var plan = await f.Service.CreatePlanAsync(scan.Id, [source.Id]); Assert.Equal(scan.ExpiresAt, plan.ExpiresAt); }
    }

    [Theory]
    [InlineData("plan_expired")]
    [InlineData("consent_expired")]
    [InlineData("clock_rollback")]
    [InlineData("preflight_expired")]
    public async Task TimeAndConsentAreCheckedAgainBeforeInitialIntent(string kind)
    {
        var f = new Fixture(); var plan = await f.Plan(); f.Source.Clock.Now = plan.CreatedAt.AddSeconds(10); var consent = await f.Confirm(plan);
        if (kind == "preflight_expired") f.Source.OnDatabase = () => f.Source.Clock.Now = f.Source.Clock.Now.AddMinutes(1);
        else f.Source.Clock.Now = kind switch { "plan_expired" => plan.ExpiresAt, "consent_expired" => f.Source.Clock.Now.AddMinutes(1), _ => plan.CreatedAt.AddSeconds(5) };
        Assert.Contains((await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(plan.Id, consent))).Code, new[] { "plan_stale", "confirmation_required" });
        Assert.Empty(f.Mutation.Requests); Assert.DoesNotContain(f.Source.Store.Records, pair => pair.Key.StartsWith("privacy_receipt_", StringComparison.Ordinal));
    }

    [Fact]
    public async Task CurrentConfirmationCannotCrossServiceOrPlanAndCannotBeReplayed()
    {
        var f = new Fixture(); var plan = await f.Plan(); var consent = await f.Confirm(plan);
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => f.MakeService().ExecuteAsync(plan.Id, consent))).Code);
        var second = await f.Service.CreatePlanAsync(plan.ScanId, plan.Sources.Select(source => source.Source.Id));
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(second.Id, consent))).Code);
        var receipt = await f.Service.ExecuteAsync(plan.Id, consent); Assert.Equal(PrivacyExecutionState.Completed, receipt.State);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(plan.Id, consent))).Code);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ConfirmAsync(plan.Id, new Confirmation()))).Code);
        Assert.Single(f.Mutation.Requests);
    }

    [Fact]
    public async Task CompletedBatchBindsOneConfirmationAndPrivateReceiptWithNoBrowsingMetadata()
    {
        var f = new Fixture(); var plan = await f.Plan(2); var prompt = new Confirmation(); var consent = await f.Service.ConfirmAsync(plan.Id, prompt);
        var receipt = await f.Service.ExecuteAsync(plan.Id, consent); Assert.Equal(PrivacyExecutionState.Completed, receipt.State); Assert.Equal(2, f.Mutation.Requests.Count);
        Assert.All(f.Mutation.Requests, request => { Assert.Equal(plan.Window, request.Window); Assert.Equal(plan.OwnerSid, request.OwnerSid); Assert.Equal(plan.ExpiresAt, request.AuthorizationExpiresAt); });
        Assert.All(receipt.Items, item => { Assert.Equal(PrivacyItemState.Completed, item.State); Assert.Equal(3, item.RemovedRecords); });
        var json = System.Text.Encoding.UTF8.GetString(f.Source.Store.Records[receipt.Id]);
        foreach (var sensitive in new[] { "Default", "Profile 1", "D:", "History", "Google", "S-1-5", "schema_digest", "security_digest" }) Assert.DoesNotContain(sensitive, json);
        var read = await f.MakeService().ReadReceiptAsync(plan.Id); Assert.Equal(JsonSerializer.Serialize(receipt, ContractJson.Options), JsonSerializer.Serialize(read, ContractJson.Options));
        Assert.Single(f.Source.Store.Records, pair => pair.Key.StartsWith("privacy_receipt_", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task InitialOrItemIntentFailureNeverDispatchesNativeMutation(bool item)
    {
        var f = new Fixture(); var plan = await f.Plan(); var consent = await f.Confirm(plan);
        f.Source.Store.FailPublication = (key, bytes) => key.StartsWith("privacy_receipt_", StringComparison.Ordinal) && (!item ||
            JsonSerializer.Deserialize<PrivacyReceipt>(bytes, ContractJson.Options)!.Items[0].State == PrivacyItemState.Executing);
        Assert.Equal("journal_write_failed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(plan.Id, consent))).Code); Assert.Empty(f.Mutation.Requests);
        if (item)
        {
            Assert.Equal(PrivacyItemState.Pending, (await f.Service.ReadReceiptAsync(plan.Id)).Items[0].State);
            Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ConfirmAsync(plan.Id, new Confirmation()))).Code);
        }
    }

    [Fact]
    public async Task OutcomePublicationFailureRetainsExecutingIntentAndNeverRetries()
    {
        var f = new Fixture(); var plan = await f.Plan(); var consent = await f.Confirm(plan);
        f.Source.Store.FailPublication = (key, bytes) => key.StartsWith("privacy_receipt_", StringComparison.Ordinal) &&
            JsonSerializer.Deserialize<PrivacyReceipt>(bytes, ContractJson.Options)!.Items[0].State == PrivacyItemState.Completed;
        Assert.Equal("journal_write_failed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(plan.Id, consent))).Code);
        Assert.Single(f.Mutation.Requests); var read = await f.Service.ReadReceiptAsync(plan.Id); Assert.Equal(PrivacyItemState.Executing, read.Items[0].State);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(plan.Id, consent))).Code);
    }

    [Theory]
    [InlineData("unknown")]
    [InlineData("exception")]
    [InlineData("invalid_count")]
    [InlineData("private_reason")]
    public async Task AmbiguousNativeResultsStopTheBatchWithoutAssumingRollback(string kind)
    {
        var f = new Fixture(); var plan = await f.Plan(2);
        f.Mutation.Apply = (_, _) => kind == "exception" ? throw new IOException("private data") : Task.FromResult(kind switch
        {
            "unknown" => new PrivacyMutationResult(PrivacyMutationOutcome.Unknown), "invalid_count" => new(PrivacyMutationOutcome.Completed, 2),
            _ => new(PrivacyMutationOutcome.RolledBack, 0, "private_cookie_value")
        });
        var result = await f.Service.ExecuteAsync(plan.Id, await f.Confirm(plan)); Assert.Equal(PrivacyExecutionState.Partial, result.State); Assert.Single(f.Mutation.Requests);
        Assert.Equal(PrivacyItemState.Unknown, result.Items[0].State); Assert.Null(result.Items[0].RemovedRecords);
        Assert.Equal(PrivacyItemState.Skipped, result.Items[1].State); Assert.Equal("previous_outcome_unknown", result.Items[1].Reason);
        Assert.DoesNotContain("private_cookie_value", JsonSerializer.Serialize(result, ContractJson.Options));
    }

    [Fact]
    public async Task KnownRollbackCanContinueOtherSourcesAndDoesNotHideCommittedItems()
    {
        var f = new Fixture(); var plan = await f.Plan(3);
        f.Mutation.Apply = (request, _) => Task.FromResult(f.Mutation.Requests.Count == 2
            ? new PrivacyMutationResult(PrivacyMutationOutcome.RolledBack, 0, "privacy_database_busy") : new(PrivacyMutationOutcome.Completed, request.Source.RecordCount));
        var receipt = await f.Service.ExecuteAsync(plan.Id, await f.Confirm(plan)); Assert.Equal(3, f.Mutation.Requests.Count);
        Assert.Equal(new[] { PrivacyItemState.Completed, PrivacyItemState.Failed, PrivacyItemState.Completed }, receipt.Items.Select(item => item.State));
        Assert.Equal(PrivacyExecutionState.Partial, receipt.State);
    }

    [Fact]
    public async Task CancellationWaitsForTheActualResultAndRetainsTheMutationLease()
    {
        var f = new Fixture(); var plan = await f.Plan(2); var completion = new TaskCompletionSource<PrivacyMutationResult>();
        f.Mutation.Apply = (_, _) => completion.Task; var consent = await f.Confirm(plan); using var stop = new CancellationTokenSource();
        var task = f.Service.ExecuteAsync(plan.Id, consent, stop.Token); Assert.Single(f.Mutation.Requests); stop.Cancel(); Assert.False(task.IsCompleted);
        Assert.Equal("store_busy", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ReadPlanAsync(plan.Id))).Code);
        completion.SetResult(new(PrivacyMutationOutcome.Completed, 3)); var receipt = await task;
        Assert.Equal(PrivacyItemState.Completed, receipt.Items[0].State); Assert.Equal(PrivacyItemState.Cancelled, receipt.Items[1].State);
        Assert.Single(f.Mutation.Requests); Assert.Equal(PrivacyExecutionState.Partial, receipt.State);
    }

    [Fact]
    public async Task BrowserStartingDuringLastPreflightStopsBeforeIntent()
    {
        var f = new Fixture(); var plan = await f.Plan(2); var consent = await f.Confirm(plan); var reads = 0;
        f.Source.OnDatabase = () => { if (++reads == 2) f.Source.Activity = ActivityState.Active; };
        await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(plan.Id, consent)); Assert.Empty(f.Mutation.Requests);
        Assert.DoesNotContain(f.Source.Store.Records, pair => pair.Key.StartsWith("privacy_receipt_", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("source")]
    [InlineData("count")]
    [InlineData("window")]
    [InlineData("owner")]
    [InlineData("scan_digest")]
    [InlineData("cookie_ack")]
    public async Task PlanReadRejectsRecomputedButInconsistentMetadata(string change)
    {
        var f = new Fixture(); var plan = await f.Plan(cookies: true);
        plan = change switch
        {
            "source" => plan with { Sources = [plan.Sources[0] with { Source = plan.Sources[0].Source with { Profile = "Profile 9" } }] },
            "count" => plan with { Sources = [plan.Sources[0] with { RecordCount = 4 }] }, "owner" => plan with { OwnerSid = "S-1-5-21-9999" },
            "window" => plan with { Window = PrivacyWindow.Create(PrivacyTimeRange.LastDay, plan.Window.End) },
            "scan_digest" => plan with { ScanDigest = "sha256:" + new string('b', 64) }, _ => plan with { SignOutAcknowledged = false }
        };
        plan = plan with { Digest = Digest(plan with { Digest = "" }) }; f.Source.Store.Records[plan.Id] = JsonSerializer.SerializeToUtf8Bytes(plan, ContractJson.Options);
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ReadPlanAsync(plan.Id))).Code); Assert.Empty(f.Mutation.Requests);
    }

    [Theory]
    [InlineData("count")]
    [InlineData("order")]
    [InlineData("state")]
    [InlineData("plan")]
    [InlineData("reason")]
    public async Task ReceiptReadNeverReplaysCorruptOutcomes(string change)
    {
        var f = new Fixture(); var plan = await f.Plan(2); var receipt = await f.Service.ExecuteAsync(plan.Id, await f.Confirm(plan));
        receipt = change switch
        {
            "count" => receipt with { Items = receipt.Items.SetItem(0, receipt.Items[0] with { RemovedRecords = 2 }) },
            "order" => receipt with { Items = receipt.Items.Reverse().ToImmutableArray() }, "state" => receipt with { State = PrivacyExecutionState.Partial },
            "plan" => receipt with { PlanDigest = "sha256:" + new string('b', 64) },
            _ => receipt with { Items = receipt.Items.SetItem(0, receipt.Items[0] with { State = PrivacyItemState.Unknown, RemovedRecords = null, Reason = "private" }), State = PrivacyExecutionState.Partial }
        };
        receipt = receipt with { Digest = Digest(receipt with { Digest = "" }) }; f.Source.Store.Records[receipt.Id] = JsonSerializer.SerializeToUtf8Bytes(receipt, ContractJson.Options);
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ReadReceiptAsync(plan.Id))).Code); Assert.Equal(2, f.Mutation.Requests.Count);
    }
    private static string Digest<T>(T value) => "sha256:" + Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(value, ContractJson.Options)));
}
