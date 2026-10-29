using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class StorageRemovalTests
{
    private static CleanupService Service(CleanupTests.Fixture fixture) => new(fixture.Store, fixture.Validator, new StorageScanner(fixture.Files, fixture.Clock),
        fixture.Protection, fixture.Activity, fixture.Mutation, fixture.Clock, storageFiles: fixture.Files);
    private static Task<ScanSnapshot> Scan(CleanupTests.Fixture fixture) => new StorageScanner(fixture.Files, fixture.Clock).ScanAsync(fixture.Workspace.Path, new(), null, default);

    [Theory]
    [InlineData("project-0/target")]
    [InlineData("project-0/target/cache.bin")]
    public async Task ExplicitFileAndDirectoryRemovalUsesDurableHistoryAndCannotReplay(string relative)
    {
        var fixture = await CleanupTests.Fixture.Create();
        var service = Service(fixture);
        var path = fixture.Workspace.Path.Append(relative);
        var plan = await service.CreateStoragePlanAsync(await Scan(fixture), [path]);
        Assert.Equal(3, plan.Version);
        Assert.Single(plan.Items);
        Assert.Equal(path, plan.Items[0].Path);
        var consent = await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation());
        var result = await service.ExecuteAsync(plan.Id, consent);
        Assert.Equal(CleanupExecutionState.Completed, result.State);
        Assert.False(fixture.Files.Entries.ContainsKey(path.Value));
        Assert.True(fixture.Files.Entries.ContainsKey(fixture.Workspace.Path.Append("project-0/Cargo.toml").Value));
        var history = new CleanupHistoryService(fixture.Store, fixture.Validator, fixture.Files, new StorageScanner(fixture.Files), fixture.Protection.OwnerSid);
        var saved = (await history.ShowAsync(result.Id)).Execution;
        Assert.Equal(result.Id, saved.Id);
        Assert.Equal(result.PlanDigest, saved.PlanDigest);
        Assert.Equal(result.State, saved.State);
        Assert.Equal(result.Items.ToArray(), saved.Items.ToArray());
        Assert.Equal("verified_permanent", (await history.InspectAsync(result.Id, new())).Items[0].Assessment);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation()))).Code);
    }

    [Fact]
    public async Task RootAndOverlappingSelectionsCannotCreatePlans()
    {
        var fixture = await CleanupTests.Fixture.Create();
        var snapshot = await Scan(fixture);
        foreach (var paths in new[] { new[] { snapshot.Root }, new[] { snapshot.Root.Append("project-0/target"), snapshot.Root.Append("project-0/target/cache.bin") } })
            Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => Service(fixture).CreateStoragePlanAsync(snapshot, paths))).Code);
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task ChangedManifestAfterCurrentConfirmationReportsFailureWithoutMutation()
    {
        var fixture = await CleanupTests.Fixture.Create();
        var service = Service(fixture);
        var path = fixture.Workspace.Path.Append("project-0/target");
        var plan = await service.CreateStoragePlanAsync(await Scan(fixture), [path]);
        var consent = await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation());
        fixture.Files.Add(path.Append("new.bin").Value);
        var result = await service.ExecuteAsync(plan.Id, consent);
        Assert.Equal("plan_stale", Assert.Single(result.Items).Reason);
        Assert.Equal(CleanupItemState.Failed, result.Items[0].State);
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task CurrentRegisteredExclusionsProtectDescendantsAndInvalidateConfirmation()
    {
        var fixture = await CleanupTests.Fixture.Create();
        var service = Service(fixture);
        var snapshot = await Scan(fixture);
        var path = snapshot.Root.Append("project-0/target");
        var plan = await service.CreateStoragePlanAsync(snapshot, [path]);
        var consent = await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation());
        await fixture.Configuration.SetExclusionAsync(fixture.Workspace.Id, "**/cache.bin", false);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan.Id, consent))).Code);
        Assert.Equal("excluded", (await Assert.ThrowsAsync<ShouException>(() => service.CreateStoragePlanAsync(snapshot, [path]))).Code);
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Theory]
    [InlineData(ActivityState.Active, "active_target")]
    [InlineData(ActivityState.Unknown, "activity_unknown")]
    public async Task ActiveOrUnverifiableFilesRemainUntouched(ActivityState state, string reason)
    {
        var fixture = await CleanupTests.Fixture.Create();
        fixture.Activity.State = state;
        var snapshot = await Scan(fixture);
        Assert.Equal(reason, (await Assert.ThrowsAsync<ShouException>(() => Service(fixture).CreateStoragePlanAsync(snapshot, [fixture.Workspace.Path.Append("project-0/target/cache.bin")]))).Code);
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task BatchReviewSkipsUnreadableTargetsAndExecutesCompleteSiblings(bool incompleteAtDiscovery)
    {
        var fixture = await CleanupTests.Fixture.Create(2);
        var denied = fixture.Workspace.Path.Append("project-0/target");
        var available = fixture.Workspace.Path.Append("project-1/target");
        if (incompleteAtDiscovery) fixture.Files.Denied.Add(denied.Value);
        var snapshot = await Scan(fixture);
        fixture.Files.Denied.Add(denied.Value);
        var service = Service(fixture);
        var review = await service.ReviewStorageRemovalAsync(snapshot, [denied, available]);
        Assert.Equal(new StorageRemovalSkip(denied, "coverage_incomplete"), Assert.Single(review.SkippedItems));
        var plan = Assert.IsType<CleanupPlan>(review.Plan);
        Assert.Equal(available, Assert.Single(plan.Items).Path);
        Assert.Single(plan.Sources);
        Assert.Equal(0, fixture.Mutation.Calls);
        var consent = await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation());
        var result = await service.ExecuteAsync(plan.Id, consent);
        Assert.Equal(CleanupExecutionState.Completed, result.State);
        Assert.True(fixture.Files.Entries.ContainsKey(denied.Append("cache.bin").Value));
        Assert.False(fixture.Files.Entries.ContainsKey(available.Value));
    }

    [Fact]
    public async Task AllExcludedTargetsCreateNoPlanOrExecution()
    {
        var fixture = await CleanupTests.Fixture.Create();
        var snapshot = await Scan(fixture);
        await fixture.Configuration.SetExclusionAsync(fixture.Workspace.Id, "**/cache.bin", false);
        var review = await Service(fixture).ReviewStorageRemovalAsync(snapshot, [fixture.Workspace.Path.Append("project-0/target")]);
        Assert.Null(review.Plan);
        Assert.Equal("excluded", Assert.Single(review.SkippedItems).Reason);
        Assert.DoesNotContain(fixture.Store.Records.Keys, key => key.StartsWith("plan_", StringComparison.Ordinal) || key.StartsWith("execution_", StringComparison.Ordinal));
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task BatchReviewSkipsDisappearedTargets()
    {
        var fixture = await CleanupTests.Fixture.Create(2);
        var snapshot = await Scan(fixture);
        var missing = fixture.Workspace.Path.Append("project-0/target/cache.bin");
        var available = fixture.Workspace.Path.Append("project-1/target/cache.bin");
        fixture.Files.Entries.Remove(missing.Value);
        var review = await Service(fixture).ReviewStorageRemovalAsync(snapshot, [missing, available]);
        Assert.Equal(new StorageRemovalSkip(missing, "not_found"), Assert.Single(review.SkippedItems));
        Assert.Equal(available, Assert.Single(Assert.IsType<CleanupPlan>(review.Plan).Items).Path);
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Theory]
    [InlineData(ActivityState.Active, "active_target")]
    [InlineData(ActivityState.Unknown, "activity_unknown")]
    public async Task BatchReviewKeepsActiveAndUnverifiableTargetsReadOnly(ActivityState state, string reason)
    {
        var fixture = await CleanupTests.Fixture.Create();
        fixture.Activity.State = state;
        var review = await Service(fixture).ReviewStorageRemovalAsync(await Scan(fixture), [fixture.Workspace.Path.Append("project-0/target")]);
        Assert.Null(review.Plan);
        Assert.Equal(reason, Assert.Single(review.SkippedItems).Reason);
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task BatchReviewStillRejectsStaleObjectsCancellationAndPublicationFailure()
    {
        var fixture = await CleanupTests.Fixture.Create();
        var snapshot = await Scan(fixture);
        var path = fixture.Workspace.Path.Append("project-0/target/cache.bin");
        var original = fixture.Files.Entries[path.Value];
        fixture.Files.OnInspect = entry => entry.Path == path ? entry with { LogicalBytes = entry.LogicalBytes + 1 } : entry;
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => Service(fixture).ReviewStorageRemovalAsync(snapshot, [path]))).Code);
        fixture.Files.OnInspect = null;
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Service(fixture).ReviewStorageRemovalAsync(snapshot, [path], cancellation.Token));
        fixture.Store.FailWrite = true;
        Assert.Equal("io_error", (await Assert.ThrowsAsync<ShouException>(() => Service(fixture).ReviewStorageRemovalAsync(snapshot, [path]))).Code);
        Assert.Equal(original, fixture.Files.Entries[path.Value]);
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task PermissionFailureAtAnItemBoundaryDoesNotBlockLaterStorageTargets()
    {
        var fixture = await CleanupTests.Fixture.Create(3);
        var paths = Enumerable.Range(0, 3).Select(index => fixture.Workspace.Path.Append($"project-{index}/target/cache.bin")).ToArray();
        var service = Service(fixture);
        var plan = await service.CreateStoragePlanAsync(await Scan(fixture), paths);
        fixture.Mutation.Apply = (item, _, _) =>
        {
            foreach (var entry in item.Manifest) fixture.Files.Entries.Remove(entry.Path.Value);
            if (item.Path == paths[0]) fixture.Files.OnInspect = entry => entry.Path == paths[1] ? throw new UnauthorizedAccessException() : entry;
            return Task.FromResult(new CleanupMutationResult(CleanupMutationOutcome.Completed, item.Manifest.Length));
        };
        var consent = await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation());
        var result = await service.ExecuteAsync(plan.Id, consent);
        Assert.Equal(CleanupExecutionState.Partial, result.State);
        Assert.Equal(new[] { CleanupItemState.Purged, CleanupItemState.Failed, CleanupItemState.Purged }, result.Items.Select(item => item.State));
        Assert.Equal("permission_denied", result.Items[1].Reason);
        Assert.True(fixture.Files.Entries.ContainsKey(paths[1].Value));
        Assert.Equal(2, fixture.Mutation.Calls);
    }
}
