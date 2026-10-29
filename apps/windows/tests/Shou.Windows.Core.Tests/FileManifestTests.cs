using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class FileManifestTests
{
    private static async Task<CleanupTests.Fixture> LargeFixture()
    {
        var fixture = await CleanupTests.Fixture.Create();
        var target = fixture.Workspace.Path.Append("project-0/target");
        for (var index = 0; index < 5000; index++) fixture.Files.Add(target.Append("generated-" + index + ".bin").Value);
        return fixture;
    }

    [Fact]
    public async Task LargeScansPlansAndHistoryShareBoundedVerifiedPages()
    {
        var fixture = await LargeFixture();
        var scan = await fixture.Scans.ScanAsync(fixture.Workspace.Id, new());
        Assert.True(fixture.Store.Records[scan.Id].Length < 16_384);
        Assert.Equal(2, fixture.Store.Records.Keys.Count(key => key.StartsWith(scan.Id + "_p", StringComparison.Ordinal)));
        Assert.Equal(5005, (await fixture.Scans.ResultsAsync(scan.Id)).MeasuredEntries);
        var plan = await fixture.Service.CreatePlanAsync(scan.Id, scan.Candidates.Select(candidate => candidate.Id));
        Assert.True(fixture.Store.Records[plan.Id].Length < 16_384);
        Assert.All(fixture.Store.Records.Values, bytes => Assert.True(bytes.Length < 4_194_304));
        Assert.Equal(plan.Items[0].Manifest.ToArray(), (await fixture.Service.PlanAsync(plan.Id)).Items[0].Manifest.ToArray());
        var serialized = JsonSerializer.SerializeToUtf8Bytes(plan with { Digest = "" }, ContractJson.Options);
        Assert.Equal("sha256:" + Convert.ToHexStringLower(SHA256.HashData(serialized)), plan.Digest);
        var execution = await fixture.Service.ExecuteAsync(plan.Id, await fixture.Service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation()));
        var history = new CleanupHistoryService(fixture.Store, fixture.Validator, fixture.Files, new StorageScanner(fixture.Files), fixture.Protection.OwnerSid);
        Assert.Equal(plan.Items[0].Manifest.ToArray(), (await history.ShowAsync(execution.Id)).Plan.Items[0].Manifest.ToArray());
        Assert.Single((await history.ListAsync()).Entries);
        Assert.True(fixture.Files.Entries.ContainsKey(fixture.Workspace.Path.Append("project-0/Cargo.toml").Value));
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation()))).Code);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("bytes")]
    [InlineData("reordered")]
    [InlineData("metadata")]
    public async Task CorruptPlanPagesCannotReachConfirmationOrMutation(string corruption)
    {
        var fixture = await LargeFixture();
        var plan = await fixture.Plan();
        var key = fixture.Store.Records.Keys.First(key => key.StartsWith(plan.Id + "_0_p", StringComparison.Ordinal));
        if (corruption == "missing") fixture.Store.Records.Remove(key);
        else if (corruption == "bytes") fixture.Store.Records[key][20] ^= 1;
        else if (corruption == "reordered")
        {
            var page = JsonNode.Parse(fixture.Store.Records[key])!.AsArray();
            var first = page[0]!.DeepClone();
            page[0] = page[1]!.DeepClone(); page[1] = first;
            fixture.Store.Records[key] = JsonSerializer.SerializeToUtf8Bytes(page);
        }
        else
        {
            var envelope = JsonNode.Parse(fixture.Store.Records[plan.Id])!;
            envelope["manifests"]![0]!["count"] = 1;
            fixture.Store.Records[plan.Id] = JsonSerializer.SerializeToUtf8Bytes(envelope);
        }
        var confirmation = new CleanupTests.Confirmation();
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ConfirmAsync(plan.Id, confirmation))).Code);
        Assert.Null(confirmation.Review);
        Assert.Equal(0, fixture.Mutation.Calls);
        Assert.Equal(5005, fixture.Files.Entries.Count);
    }

    [Fact]
    public async Task CorruptScanPagesCannotBecomeAPlanOrAPageOfResults()
    {
        var fixture = await LargeFixture();
        var scan = await fixture.Scans.ScanAsync(fixture.Workspace.Id, new());
        var key = fixture.Store.Records.Keys.First(key => key.StartsWith(scan.Id + "_p", StringComparison.Ordinal));
        fixture.Store.Records.Remove(key);
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => fixture.Scans.ResultsAsync(scan.Id))).Code);
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.CreatePlanAsync(scan.Id, scan.Candidates.Select(candidate => candidate.Id)))).Code);
        Assert.DoesNotContain(fixture.Store.Records.Keys, key => RecordKey.IsId(key, "plan"));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task InterruptedPageWritesNeverPublishAuthority(bool scanWrite)
    {
        var fixture = await LargeFixture();
        var source = scanWrite ? null : await fixture.Scans.ScanAsync(fixture.Workspace.Id, new());
        var pageWrites = 0;
        fixture.Store.FailPublication = (key, _) => key.Contains("_p", StringComparison.Ordinal) && ++pageWrites == 2;
        var error = scanWrite
            ? await Assert.ThrowsAsync<ShouException>(() => fixture.Scans.ScanAsync(fixture.Workspace.Id, new()))
            : await Assert.ThrowsAsync<ShouException>(() => fixture.Service.CreatePlanAsync(source!.Id, source.Candidates.Select(candidate => candidate.Id)));
        Assert.Equal("io_error", error.Code);
        Assert.Equal(2, pageWrites);
        Assert.DoesNotContain(fixture.Store.Records.Keys, key => RecordKey.IsId(key, scanWrite ? "scan" : "plan"));
        Assert.Equal(0, fixture.Mutation.Calls);
        Assert.Equal(5005, fixture.Files.Entries.Count);
    }

    [Fact]
    public async Task CancelledPagePublicationLeavesOnlyUnreferencedEvidence()
    {
        var fixture = await LargeFixture();
        using var stopped = new CancellationTokenSource();
        fixture.Store.FailPublication = (key, _) => { if (key.Contains("_p", StringComparison.Ordinal)) stopped.Cancel(); return false; };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Scans.ScanAsync(fixture.Workspace.Id, new(), stopped.Token));
        Assert.DoesNotContain(fixture.Store.Records.Keys, key => RecordKey.IsId(key, "scan"));
        Assert.Equal(5005, fixture.Files.Entries.Count);
    }

    private sealed class VerifiedMutation(CleanupTests.Fixture fixture) : ICleanupMutation
    {
        public bool VerifiesMutationManifest => true;
        public bool Supports(CleanupAction action) => true;
        public Action<CleanupPlanItem>? BeforeApply;
        public Task<CleanupMutationResult> ApplyAsync(Workspace workspace, CleanupPlanItem item, CleanupAction action, CancellationToken token) =>
            ApplyAsync(workspace, item, action, null, token);
        public async Task<CleanupMutationResult> ApplyAsync(Workspace workspace, CleanupPlanItem item, CleanupAction action,
            IProgress<CleanupMutationProgress>? progress, CancellationToken token)
        {
            BeforeApply?.Invoke(item);
            var snapshot = await new StorageScanner(fixture.Files).ScanAsync(item.Path, new(), null, token);
            var observed = snapshot.Entries.Select(entry => entry.Entry).OrderBy(entry => entry.Path.Value, StringComparer.Ordinal).ToArray();
            progress?.Report(new("checking", item.Path, 0));
            if (token.IsCancellationRequested) return new(CleanupMutationOutcome.Cancelled, Reason: "cancelled");
            if (!snapshot.IsComplete || !observed.SequenceEqual(item.Manifest) || item.Context.Any(entry =>
                !fixture.Files.Entries.TryGetValue(entry.Path.Value, out var actual) || !FileManifestVerification.MatchesEntry(actual, entry, true)))
                return new(CleanupMutationOutcome.Failed, Reason: "plan_stale");
            var result = await fixture.Mutation.ApplyAsync(workspace, item, action, token);
            progress?.Report(new("purging", item.Path, result.RemovedEntries));
            return result;
        }
    }
    private sealed class Progress(Action<CleanupProgress> report) : IProgress<CleanupProgress> { public void Report(CleanupProgress value) => report(value); }

    [Fact]
    public async Task VerifiedAdapterChecksEachItemAndReportsRealEntryProgress()
    {
        var fixture = await CleanupTests.Fixture.Create(8);
        var plan = await fixture.Plan();
        var service = new CleanupService(fixture.Store, fixture.Validator, new StorageScanner(fixture.Files), fixture.Protection, fixture.Activity,
            new VerifiedMutation(fixture), fixture.Clock);
        var consent = await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation());
        fixture.Files.Enumerated.Clear();
        var updates = new List<CleanupProgress>();
        Assert.Equal(CleanupExecutionState.Completed, (await service.ExecuteAsync(plan.Id, consent, new Progress(updates.Add))).State);
        Assert.Equal(8, fixture.Files.Enumerated.Count(path => path == fixture.Workspace.Path.Value));
        Assert.Contains(updates, update => update.Phase == "checking" && update.Path is not null);
        Assert.Contains(updates, update => update.Phase == "purging" && update.ProcessedEntries > 0 && update.TotalEntries == 16);
        Assert.Equal(16, updates.Last().ProcessedEntries);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task NativeBoundaryStillRejectsChangedContentsAndContext(bool context)
    {
        var fixture = await CleanupTests.Fixture.Create(2);
        var plan = await fixture.Plan();
        var mutation = new VerifiedMutation(fixture);
        mutation.BeforeApply = item =>
        {
            if (item.Id != plan.Items[1].Id) return;
            if (context)
            {
                var path = item.Path.Parent!.Append("Cargo.toml");
                fixture.Files.Entries[path.Value] = fixture.Files.Entries[path.Value] with { LogicalBytes = 99 };
            }
            else fixture.Files.Add(item.Path.Append("unconfirmed.bin").Value);
        };
        var service = new CleanupService(fixture.Store, fixture.Validator, new StorageScanner(fixture.Files), fixture.Protection, fixture.Activity, mutation, fixture.Clock);
        var result = await service.ExecuteAsync(plan.Id, await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation()));
        Assert.Equal(CleanupItemState.Purged, result.Items[0].State);
        Assert.Equal(CleanupItemState.Failed, result.Items[1].State);
        Assert.True(fixture.Files.Entries.ContainsKey(plan.Items[1].Path.Value));
        Assert.Equal(1, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task StoppingDuringNativeCheckingPreservesTargetsAndDurableCancellation()
    {
        var fixture = await CleanupTests.Fixture.Create();
        var plan = await fixture.Plan();
        using var stopped = new CancellationTokenSource();
        var service = new CleanupService(fixture.Store, fixture.Validator, new StorageScanner(fixture.Files), fixture.Protection, fixture.Activity, new VerifiedMutation(fixture), fixture.Clock);
        var result = await service.ExecuteAsync(plan.Id, await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation()),
            new Progress(value => { if (value.ItemId is not null && value.Phase == "checking") stopped.Cancel(); }), stopped.Token);
        Assert.Equal(CleanupExecutionState.Cancelled, result.State);
        Assert.Equal(0, fixture.Mutation.Calls);
        Assert.Equal(5, fixture.Files.Entries.Count);
        Assert.Equal(CleanupExecutionState.Cancelled, (await service.ExecutionAsync(plan.Id))!.State);
    }
}
