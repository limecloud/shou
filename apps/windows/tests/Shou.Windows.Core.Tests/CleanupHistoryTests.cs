using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shou.Windows.Core;
using Fixture = Shou.Windows.Core.Tests.CleanupTests.Fixture;

namespace Shou.Windows.Core.Tests;

public sealed class CleanupHistoryTests
{
    private static CleanupHistoryService History(Fixture fixture, TimeProvider? clock = null, IStorageScanner? scanner = null) =>
        new(fixture.Store, fixture.Validator, fixture.Files, scanner ?? new StorageScanner(fixture.Files, clock ?? fixture.Clock),
            fixture.Protection.OwnerSid, clock ?? fixture.Clock);

    private static async Task<(CleanupPlan Plan, CleanupExecution Execution)> Seed(Fixture fixture, CleanupAction action = CleanupAction.Permanent,
        CleanupItemState state = CleanupItemState.Purging, CleanupExecutionState executionState = CleanupExecutionState.Executing)
    {
        var plan = await fixture.Plan(action);
        var execution = new CleanupExecution(1, "execution_" + plan.Id[5..], plan.Id, plan.Digest, action, fixture.Clock.Now, fixture.Clock.Now,
            executionState, plan.Items.Select(item => new CleanupItemResult(item.Id, state,
                state == CleanupItemState.Purged ? item.Manifest.Length : 0,
                ResultPath: state == CleanupItemState.Trashed ? WindowsPath.Parse("C:/$Recycle.Bin/fixture/" + item.Id) : null,
                ResultIdentity: state == CleanupItemState.Trashed ? item.Manifest[0].Identity : null)).ToImmutableArray());
        fixture.Store.Records[execution.Id] = JsonSerializer.SerializeToUtf8Bytes(execution, ContractJson.Options);
        return (plan, execution);
    }

    [Fact]
    public async Task EmptyHistoryAndMissingDetailsDoNotWriteRecords()
    {
        var fixture = await Fixture.Create();
        var writes = fixture.Store.Writes;
        var page = await History(fixture).ListAsync();
        Assert.Equal("complete", page.State);
        Assert.Empty(page.Entries);
        Assert.Equal(0, page.TotalCount);
        Assert.Null(page.NextCursor);
        Assert.Equal("not_found", (await Assert.ThrowsAsync<ShouException>(() => History(fixture).ShowAsync("execution_" + new string('0', 32)))).Code);
        Assert.Equal(writes, fixture.Store.Writes);
    }

    [Fact]
    public async Task ListingUsesStableOrderAndInvalidatesCursorsWhenAnyJournalBytesChange()
    {
        var fixture = await Fixture.Create();
        var first = await Seed(fixture);
        fixture.Clock.Now += TimeSpan.FromSeconds(1);
        var second = await Seed(fixture);
        var history = History(fixture);
        var page = await history.ListAsync(1);
        Assert.Equal(second.Execution.Id, Assert.Single(page.Entries).ExecutionId);
        Assert.False(page.Entries[0].PlanVerified);
        Assert.True(page.Entries[0].NeedsVerification);
        Assert.NotNull(page.NextCursor);
        Assert.Equal(first.Execution.Id, Assert.Single((await history.ListAsync(1, page.NextCursor)).Entries).ExecutionId);
        fixture.Store.Records[first.Execution.Id] = fixture.Store.Records[first.Execution.Id].Concat(" "u8.ToArray()).ToArray();
        Assert.Equal("source_changed", (await Assert.ThrowsAsync<ShouException>(() => history.ListAsync(1, page.NextCursor))).Code);
        Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => history.ListAsync(2, page.NextCursor))).Code);
    }

    [Fact]
    public async Task CorruptRowsRemainVisibleWithoutPreventingOtherSummariesOrGrantingPlanVerification()
    {
        var fixture = await Fixture.Create();
        var saved = await Seed(fixture);
        var corruptId = "execution_" + new string('0', 32);
        fixture.Store.Records[corruptId] = "{}"u8.ToArray();
        fixture.Store.Records.Remove(saved.Plan.Id);
        var page = await History(fixture).ListAsync(1);
        Assert.Equal("partial", page.State);
        Assert.Equal(2, page.TotalCount);
        Assert.Equal(saved.Execution.Id, Assert.Single(page.Entries).ExecutionId);
        Assert.Equal(new CleanupHistoryIssue(corruptId, "store_corrupt"), Assert.Single(page.Issues));
        Assert.Null(page.NextCursor);
        Assert.Equal("not_found", (await Assert.ThrowsAsync<ShouException>(() => History(fixture).ShowAsync(saved.Execution.Id))).Code);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(501)]
    public async Task InvalidPagesAndCursorsFailBeforeOpeningStorage(int limit)
    {
        var fixture = await Fixture.Create();
        fixture.Store.Busy = true;
        Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => History(fixture).ListAsync(limit))).Code);
        Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => History(fixture).ListAsync(cursor: "../bad"))).Code);
    }

    [Fact]
    public async Task DirectoryAndTotalReadBudgetsAreEnforcedWithoutWriting()
    {
        var fixture = await Fixture.Create();
        for (var index = 0; index <= CleanupHistoryService.MaximumDirectoryEntries; index++) fixture.Store.Records["record_" + index] = [];
        Assert.Equal("resource_limit", (await Assert.ThrowsAsync<ShouException>(() => History(fixture).ListAsync())).Code);
        fixture = await Fixture.Create();
        var saved = await Seed(fixture);
        var large = new byte[1_048_576];
        Array.Fill(large, (byte)' ');
        for (var index = 0; index < 33; index++) fixture.Store.Records["execution_" + index.ToString("x32")] = large;
        Assert.Equal("resource_limit", (await Assert.ThrowsAsync<ShouException>(() => History(fixture).ListAsync())).Code);
        Assert.Contains(saved.Plan.Id, fixture.Store.Records.Keys);
    }

    [Fact]
    public async Task ReadableCorruptionDoesNotPreventPagingOtherRows()
    {
        var fixture = await Fixture.Create();
        await Seed(fixture);
        await Seed(fixture);
        fixture.Store.Records["execution_" + new string('0', 32)] = "{}"u8.ToArray();
        var first = await History(fixture).ListAsync(1);
        Assert.Equal("partial", first.State);
        Assert.NotNull(first.NextCursor);
        var second = await History(fixture).ListAsync(1, first.NextCursor);
        Assert.Equal("partial", second.State);
        Assert.NotEqual(first.Entries[0].ExecutionId, Assert.Single(second.Entries).ExecutionId);
        Assert.Single(second.Issues);
        Assert.Null(second.NextCursor);
    }

    [Fact]
    public async Task AReplacementRootIsChangedWithoutTraversingItAndForeignOwnerPlansAreRejected()
    {
        var fixture = await Fixture.Create();
        var saved = await Seed(fixture);
        var root = saved.Plan.Items[0].Path.Value;
        fixture.Files.Entries[root] = fixture.Files.Entries[root] with { Identity = new(1, new string('0', 32), fixture.Protection.OwnerSid) };
        fixture.Files.Enumerated.Clear();
        var result = await History(fixture).InspectAsync(saved.Execution.Id, new());
        Assert.Equal(HistoryLocationState.Changed, Assert.Single(result.Items).Original.State);
        Assert.Empty(fixture.Files.Enumerated);
        var foreign = new CleanupHistoryService(fixture.Store, fixture.Validator, fixture.Files, new StorageScanner(fixture.Files), "S-1-5-21-2000");
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => foreign.ShowAsync(saved.Execution.Id))).Code);
    }

    [Fact]
    public async Task DetailBindsExecutionToItsPlanAndAllowsExpiredHistoricalPlans()
    {
        var fixture = await Fixture.Create();
        var saved = await Seed(fixture);
        fixture.Clock.Now += TimeSpan.FromDays(1);
        var detail = await History(fixture).ShowAsync(saved.Execution.Id);
        Assert.Equal(saved.Plan.Digest, detail.Plan.Digest);
        Assert.True(detail.Unfinished);
        Assert.True(detail.NeedsVerification);
        Assert.False(detail.RecoveryAvailable);
        Assert.Equal(saved.Plan.Digest, (await History(fixture).PlanAsync(saved.Plan.Id)).Digest);
        var node = JsonNode.Parse(fixture.Store.Records[saved.Execution.Id])!;
        node["plan_digest"] = "sha256:" + new string('0', 64);
        fixture.Store.Records[saved.Execution.Id] = Encoding.UTF8.GetBytes(node.ToJsonString());
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => History(fixture).ShowAsync(saved.Execution.Id))).Code);
    }

    [Theory]
    [InlineData("completed_intent")]
    [InlineData("partial_success")]
    [InlineData("wrong_action")]
    [InlineData("foreign_item")]
    [InlineData("extra_field")]
    [InlineData("negative_count")]
    public async Task InvalidExecutionStatesAndBindingsAreRejected(string change)
    {
        var fixture = await Fixture.Create();
        var saved = await Seed(fixture);
        var node = JsonNode.Parse(fixture.Store.Records[saved.Execution.Id])!;
        switch (change)
        {
            case "completed_intent": node["state"] = "completed"; break;
            case "partial_success": node["state"] = "partial"; node["items"]![0]!["state"] = "purged"; node["items"]![0]!["removed_entries"] = saved.Plan.Items[0].Manifest.Length; break;
            case "wrong_action": node["action"] = "trash"; break;
            case "foreign_item": node["items"]![0]!["item_id"] = "item_" + new string('0', 32); break;
            case "extra_field": node["approved"] = true; break;
            case "negative_count": node["items"]![0]!["removed_entries"] = -1; break;
        }
        fixture.Store.Records[saved.Execution.Id] = Encoding.UTF8.GetBytes(node.ToJsonString());
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => History(fixture).ShowAsync(saved.Execution.Id))).Code);
    }

    [Theory]
    [InlineData("wrong_identity")]
    [InlineData("original_path")]
    [InlineData("removed_count")]
    public async Task TrashedReceiptsRequireOriginalIdentityNewLocationAndNoRemovalCount(string change)
    {
        var fixture = await Fixture.Create();
        var saved = await Seed(fixture, CleanupAction.Trash, CleanupItemState.Trashed, CleanupExecutionState.Completed);
        var node = JsonNode.Parse(fixture.Store.Records[saved.Execution.Id])!;
        switch (change)
        {
            case "wrong_identity": node["items"]![0]!["result_identity"]!["file_id"] = new string('0', 32); break;
            case "original_path": node["items"]![0]!["result_path"] = saved.Plan.Items[0].Path.Value; break;
            case "removed_count": node["items"]![0]!["removed_entries"] = 1; break;
        }
        fixture.Store.Records[saved.Execution.Id] = Encoding.UTF8.GetBytes(node.ToJsonString());
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => History(fixture).ShowAsync(saved.Execution.Id))).Code);
    }

    [Theory]
    [InlineData(CleanupItemState.Purging, CleanupExecutionState.Executing)]
    [InlineData(CleanupItemState.Unknown, CleanupExecutionState.Unknown)]
    public async Task MissingOriginalNeverUpgradesAnUncertainJournal(CleanupItemState itemState, CleanupExecutionState executionState)
    {
        var fixture = await Fixture.Create();
        var saved = await Seed(fixture, state: itemState, executionState: executionState);
        foreach (var entry in saved.Plan.Items[0].Manifest) fixture.Files.Entries.Remove(entry.Path.Value);
        var bytes = fixture.Store.Records[saved.Execution.Id].ToArray();
        var writes = fixture.Store.Writes;
        var result = await History(fixture).InspectAsync(saved.Execution.Id, new());
        Assert.Equal(executionState, result.RecordedState);
        Assert.True(result.NeedsVerification);
        Assert.Equal("needs_verification", Assert.Single(result.Items).Assessment);
        Assert.Equal(HistoryLocationState.Missing, result.Items[0].Original.State);
        Assert.Equal(HistoryLocationState.NotRecorded, result.Items[0].Trash.State);
        Assert.Equal(bytes, fixture.Store.Records[saved.Execution.Id]);
        Assert.Equal(writes, fixture.Store.Writes);
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task KnownPermanentResultsAndUnchangedPendingItemsRemainDistinct()
    {
        var fixture = await Fixture.Create();
        var saved = await Seed(fixture, state: CleanupItemState.Purged, executionState: CleanupExecutionState.Completed);
        foreach (var entry in saved.Plan.Items[0].Manifest) fixture.Files.Entries.Remove(entry.Path.Value);
        var result = await History(fixture).InspectAsync(saved.Execution.Id, new());
        Assert.Equal("verified_permanent", Assert.Single(result.Items).Assessment);
        Assert.False(result.NeedsVerification);
        Assert.False(result.Unfinished);
        fixture = await Fixture.Create();
        saved = await Seed(fixture, state: CleanupItemState.Pending);
        result = await History(fixture).InspectAsync(saved.Execution.Id, new());
        Assert.Equal("unchanged", Assert.Single(result.Items).Assessment);
        Assert.True(result.Unfinished);
        Assert.True(result.NeedsVerification);
    }

    [Fact]
    public async Task InspectionComparesEveryEntryAndDoesNotAcceptChangedOrPartialTrees()
    {
        var fixture = await Fixture.Create();
        var saved = await Seed(fixture, state: CleanupItemState.Pending);
        fixture.Files.Add(saved.Plan.Items[0].Path.Append("new.bin").Value);
        var result = await History(fixture).InspectAsync(saved.Execution.Id, new());
        Assert.Equal(HistoryLocationState.Changed, Assert.Single(result.Items).Original.State);
        Assert.Equal("needs_verification", result.Items[0].Assessment);
        fixture.Files.Denied.Add(saved.Plan.Items[0].Path.Value);
        result = await History(fixture).InspectAsync(saved.Execution.Id, new());
        Assert.Equal("partial", result.State);
        Assert.Equal(HistoryLocationState.Unavailable, result.Items[0].Original.State);
        Assert.Equal("permission_denied", result.Items[0].Original.Reason);
    }

    [Fact]
    public async Task ASharedEntryBudgetAppliesAcrossAllTargets()
    {
        var fixture = await Fixture.Create(2);
        var saved = await Seed(fixture, state: CleanupItemState.Pending);
        var result = await History(fixture).InspectAsync(saved.Execution.Id, new(MaxEntries: 3));
        Assert.Equal("partial", result.State);
        Assert.Equal(3, result.ObservedEntries);
        Assert.Equal(HistoryLocationState.Matches, result.Items[0].Original.State);
        Assert.Equal("entry_limit", result.Items[1].Original.Reason);
        Assert.Equal(0, result.Items[1].Original.ObservedEntries);
    }

    [Fact]
    public async Task OnlyRecordedTrashLocationsAreObservedAndConflictsCannotAuthorizeRecovery()
    {
        var fixture = await Fixture.Create();
        var saved = await Seed(fixture, CleanupAction.Trash, CleanupItemState.Trashed, CleanupExecutionState.Completed);
        var source = saved.Plan.Items[0];
        var destination = saved.Execution.Items[0].ResultPath!;
        foreach (var entry in source.Manifest)
        {
            fixture.Files.Entries.Remove(entry.Path.Value);
            var movedPath = entry.Path == source.Path ? destination : destination.Append(entry.Path.RelativeTo(source.Path));
            fixture.Files.Entries[movedPath.Value] = entry with { Path = movedPath };
        }
        var result = await History(fixture).InspectAsync(saved.Execution.Id, new());
        Assert.Equal("verified_trash", Assert.Single(result.Items).Assessment);
        Assert.False(result.NeedsVerification);
        Assert.False(result.RecoveryAvailable);
        Assert.DoesNotContain(fixture.Files.Enumerated, path => path == destination.Parent!.Value);
        fixture.Files.Add(source.Path.Value, EntryKind.Directory);
        result = await History(fixture).InspectAsync(saved.Execution.Id, new());
        Assert.Equal("conflict", result.Items[0].Assessment);
        Assert.True(result.NeedsVerification);
        fixture.Files.Entries[destination.Value] = fixture.Files.Entries[destination.Value] with { ChangeUtc = DateTimeOffset.UtcNow };
        result = await History(fixture).InspectAsync(saved.Execution.Id, new());
        Assert.Equal(HistoryLocationState.Changed, result.Items[0].Trash.State);
    }

    [Fact]
    public async Task InspectionHoldsTheLeaseAndPropagatesCallerCancellation()
    {
        var fixture = await Fixture.Create();
        var saved = await Seed(fixture);
        using var cancellation = new CancellationTokenSource();
        fixture.Files.BeforeRead = async (_, token) =>
        {
            Assert.Equal("store_busy", (await Assert.ThrowsAsync<ShouException>(() => fixture.Configuration.SetExclusionAsync(null, "**/keep", false))).Code);
            cancellation.Cancel();
            token.ThrowIfCancellationRequested();
        };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => History(fixture).InspectAsync(saved.Execution.Id, new(), cancellation.Token));
        Assert.NotNull(await fixture.Store.ReadAsync(saved.Execution.Id, 1_048_576, default));
    }

    [Fact]
    public async Task InternalDeadlineReturnsPartialObservationsAndPreservesTheJournal()
    {
        var fixture = await Fixture.Create();
        var saved = await Seed(fixture);
        var clock = new ManualDeadlineClock();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Files.BeforeRead = async (_, token) => { entered.TrySetResult(); clock.Expire(); await Task.Delay(Timeout.InfiniteTimeSpan, token); };
        var result = await History(fixture, clock).InspectAsync(saved.Execution.Id, new());
        Assert.True(entered.Task.IsCompleted);
        Assert.Equal("partial", result.State);
        Assert.Equal("time_limit", Assert.Single(result.Items).Original.Reason);
        Assert.Equal(CleanupExecutionState.Executing, result.RecordedState);
    }
}
