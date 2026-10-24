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
    public async Task ChangedManifestAfterCurrentConfirmationCannotPublishIntent()
    {
        var fixture = await CleanupTests.Fixture.Create();
        var service = Service(fixture);
        var path = fixture.Workspace.Path.Append("project-0/target");
        var plan = await service.CreateStoragePlanAsync(await Scan(fixture), [path]);
        var consent = await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation());
        fixture.Files.Add(path.Append("new.bin").Value);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan.Id, consent))).Code);
        Assert.Equal(0, fixture.Mutation.Calls);
        Assert.DoesNotContain(fixture.Store.Records.Keys, key => key.StartsWith("execution_", StringComparison.Ordinal));
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
}
