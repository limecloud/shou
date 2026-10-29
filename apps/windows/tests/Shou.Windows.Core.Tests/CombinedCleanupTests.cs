using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class CombinedCleanupTests
{
    private sealed class Mutation(CleanupTests.Mutation inner) : ICleanupMutation
    {
        public List<Workspace> Workspaces { get; } = [];
        public bool Supports(CleanupAction action) => inner.Supports(action);
        public Task<CleanupMutationResult> ApplyAsync(Workspace workspace, CleanupPlanItem item, CleanupAction action, CancellationToken token)
        { Workspaces.Add(workspace); return inner.ApplyAsync(workspace, item, action, token); }
    }

    private sealed record Fixture(CleanupTests.Fixture Inner, Workspace Second, Mutation Mutation, CleanupService Service)
    {
        public async Task<ImmutableArray<CleanupSelection>> Scan(ScanBudget? budget = null)
        {
            var first = await Inner.Scans.ScanAsync(Inner.Workspace.Id, budget ?? new());
            var second = await Inner.Scans.ScanAsync(Second.Id, budget ?? new());
            return [new(first.Id, first.Candidates.Select(candidate => candidate.Id).ToImmutableArray()),
                new(second.Id, second.Candidates.Select(candidate => candidate.Id).ToImmutableArray())];
        }
    }

    private static async Task<Fixture> Create()
    {
        var inner = await CleanupTests.Fixture.Create();
        var path = WindowsPath.Parse("D:/Projects");
        inner.Files.Add(path.Value, EntryKind.Directory);
        inner.Files.Add(path.Append("项目 with spaces").Value, EntryKind.Directory);
        inner.Files.Add(path.Append("项目 with spaces/Cargo.toml").Value);
        inner.Files.Add(path.Append("项目 with spaces/target").Value, EntryKind.Directory);
        inner.Files.Add(path.Append("项目 with spaces/target/cache.bin").Value);
        var second = await inner.Configuration.AddWorkspaceAsync(path, "second-projects");
        var rule = JsonNode.Parse(CleanupTests.Rule("dev.second-target"))!;
        rule["scope"]!["root_ref"] = second.RootRef;
        await inner.Configuration.ImportRuleAsync(JsonSerializer.SerializeToUtf8Bytes(rule));
        await inner.Configuration.SetRuleAsync(second.Id, "dev.second-target", true);
        var mutation = new Mutation(inner.Mutation);
        return new(inner, second, mutation, new(inner.Store, inner.Validator, new StorageScanner(inner.Files, inner.Clock),
            inner.Protection, inner.Activity, mutation, inner.Clock));
    }

    [Fact]
    public async Task OneConfirmationAndJournalBindAllSourcesAndExactNativeWorkspaces()
    {
        var f = await Create();
        var selection = await f.Scan();
        var plan = await f.Service.CreatePlanAsync(selection);
        Assert.Equal(2, plan.Version); Assert.Equal(2, plan.Sources.Length); Assert.Equal(2, plan.Items.Length);
        Assert.Equal(selection.Select(value => value.ScanId).Order(), plan.Sources.Select(value => value.ScanId).Order());
        Assert.All(plan.Items, item => Assert.Contains(plan.Sources, source => source.ScanId == item.ScanId && item.Path.IsWithin(source.Workspace.Path)));
        var confirmation = new CleanupTests.Confirmation();
        var consent = await f.Service.ConfirmAsync(plan.Id, confirmation);
        Assert.Equal(plan.Digest, confirmation.Review!.Digest); Assert.Equal(2, confirmation.Review.Items.Length);
        var result = await f.Service.ExecuteAsync(plan.Id, consent);
        Assert.Equal(CleanupExecutionState.Completed, result.State);
        Assert.Equal(plan.Items.Select(item => plan.Sources.Single(source => source.ScanId == item.ScanId).Workspace), f.Mutation.Workspaces);
        Assert.Single(f.Inner.Store.Records, pair => pair.Key.StartsWith("execution_", StringComparison.Ordinal));
        Assert.Equal(JsonSerializer.Serialize(result, ContractJson.Options), JsonSerializer.Serialize(await f.Service.ExecutionAsync(plan.Id), ContractJson.Options));
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ConfirmAsync(plan.Id, confirmation))).Code);
        Assert.Equal(2, f.Inner.Mutation.Calls);
    }

    [Fact]
    public async Task ChangedSecondSourceReportsFailureAfterIndependentFirstItem()
    {
        var f = await Create(); var plan = await f.Service.CreatePlanAsync(await f.Scan());
        var consent = await f.Service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation());
        var target = plan.Items.Single(item => item.Path.IsWithin(f.Second.Path)).Manifest.Last();
        f.Inner.Files.Entries[target.Path.Value] = target with { LogicalBytes = target.LogicalBytes + 1 };
        var result = await f.Service.ExecuteAsync(plan.Id, consent);
        Assert.Equal(CleanupExecutionState.Partial, result.State);
        Assert.Single(f.Mutation.Workspaces);
        Assert.Single(result.Items, item => item.State == CleanupItemState.Failed && item.Reason == "plan_stale");
        Assert.NotNull(await f.Service.ExecutionAsync(plan.Id));
    }

    [Fact]
    public async Task ConfigurationChangeInAnySourceInvalidatesTheWholePlanBeforeConfirmation()
    {
        var f = await Create(); var plan = await f.Service.CreatePlanAsync(await f.Scan());
        await f.Inner.Configuration.SetRuleAsync(f.Second.Id, "dev.second-target", false);
        var confirmation = new CleanupTests.Confirmation();
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ConfirmAsync(plan.Id, confirmation))).Code);
        Assert.Null(confirmation.Review); Assert.Empty(f.Mutation.Workspaces);
    }

    [Fact]
    public async Task DeclinedCombinedReviewCannotIssueConsentOrSaveExecution()
    {
        var f = await Create(); var plan = await f.Service.CreatePlanAsync(await f.Scan());
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation(false)))).Code);
        Assert.Null(await f.Service.ExecutionAsync(plan.Id)); Assert.Empty(f.Mutation.Workspaces);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RepeatedScanOrMultipleScansOfOneWorkspaceCannotBecomeACombinedPlan(bool newScan)
    {
        var f = await Create(); var selection = await f.Scan();
        var duplicate = newScan ? await f.Inner.Scans.ScanAsync(f.Inner.Workspace.Id, new()) : null;
        var second = duplicate is null ? selection[0] : new(duplicate.Id, duplicate.Candidates.Select(candidate => candidate.Id).ToImmutableArray());
        Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => f.Service.CreatePlanAsync([selection[0], second]))).Code);
        Assert.DoesNotContain(f.Inner.Store.Records, pair => pair.Key.StartsWith("plan_", StringComparison.Ordinal));
    }

    [Fact]
    public async Task CandidateCannotMoveToAnotherSourceEvenWhenBothScansAreCurrent()
    {
        var f = await Create(); var selection = await f.Scan();
        var swapped = new[] { selection[0] with { CandidateIds = selection[1].CandidateIds }, selection[1] with { CandidateIds = selection[0].CandidateIds } };
        Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => f.Service.CreatePlanAsync(swapped))).Code);
        Assert.Empty(f.Mutation.Workspaces);
    }

    [Fact]
    public async Task SnapshotFromBeforeConfigurationChangeCannotJoinCurrentSnapshot()
    {
        var f = await Create(); var selection = await f.Scan();
        await f.Inner.Configuration.SetExclusionAsync(f.Second.Id, "**/keep", false);
        var scan = await f.Inner.Scans.ScanAsync(f.Second.Id, new());
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => f.Service.CreatePlanAsync([selection[0],
            new(scan.Id, scan.Candidates.Select(candidate => candidate.Id).ToImmutableArray())]))).Code);
        Assert.Empty(f.Mutation.Workspaces);
    }

    [Fact]
    public async Task LocationsShareTheValidationEntryBudget()
    {
        var f = await Create(); var selection = await f.Scan(new(MaxEntries: 9));
        await Assert.ThrowsAsync<ShouException>(() => f.Service.CreatePlanAsync(selection));
        Assert.DoesNotContain(f.Inner.Store.Records, pair => pair.Key.StartsWith("plan_", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task StopOrUnknownResultInOneLocationDoesNotDispatchOtherLocations(bool unknown)
    {
        var f = await Create(); var plan = await f.Service.CreatePlanAsync(await f.Scan());
        using var stop = new CancellationTokenSource();
        f.Inner.Mutation.Apply = (item, _, _) =>
        {
            stop.Cancel();
            return Task.FromResult(unknown ? new CleanupMutationResult(CleanupMutationOutcome.Unknown) :
                new(CleanupMutationOutcome.Completed, item.Manifest.Length));
        };
        var consent = await f.Service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation());
        var result = await f.Service.ExecuteAsync(plan.Id, consent, cancellationToken: stop.Token);
        Assert.Single(f.Mutation.Workspaces);
        Assert.Equal(unknown ? CleanupExecutionState.Unknown : CleanupExecutionState.Cancelled, result.State);
        Assert.Equal(unknown ? CleanupItemState.Skipped : CleanupItemState.Cancelled, result.Items[1].State);
        Assert.Equal(unknown ? CleanupItemState.Unknown : CleanupItemState.Purged, result.Items[0].State);
        Assert.Equal(JsonSerializer.Serialize(result, ContractJson.Options), JsonSerializer.Serialize(await f.Service.ExecutionAsync(plan.Id), ContractJson.Options));
    }

    [Theory]
    [InlineData("foreign_source")]
    [InlineData("duplicate_source")]
    [InlineData("unused_source")]
    [InlineData("workspace_swap")]
    public async Task StoredPlanRejectsMalformedSourceBindingsEvenWithARecomputedDigest(string change)
    {
        var f = await Create(); var plan = await f.Service.CreatePlanAsync(await f.Scan());
        plan = change switch
        {
            "foreign_source" => plan with { Items = plan.Items.SetItem(0, plan.Items[0] with { ScanId = RecordKey.New("scan") }) },
            "duplicate_source" => plan with { Sources = plan.Sources.Add(plan.Sources[0]) },
            "unused_source" => plan with { Sources = plan.Sources.Add(plan.Sources[0] with { ScanId = RecordKey.New("scan") }) },
            _ => plan with { Sources = plan.Sources.SetItem(0, plan.Sources[0] with { Workspace = plan.Sources[1].Workspace }) }
        };
        plan = plan with { Digest = "sha256:" + Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(plan with { Digest = "" }, ContractJson.Options))) };
        f.Inner.Store.Records[plan.Id] = JsonSerializer.SerializeToUtf8Bytes(plan, ContractJson.Options);
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => f.Service.PlanAsync(plan.Id))).Code);
        Assert.Empty(f.Mutation.Workspaces);
    }
}
