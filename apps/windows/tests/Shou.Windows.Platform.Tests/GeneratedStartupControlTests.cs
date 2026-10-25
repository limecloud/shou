using System.Runtime.InteropServices;
using System.Text.Json;
using Shou.Windows.Core;
using Xunit.Abstractions;

namespace Shou.Windows.Platform.Tests;

public sealed class GeneratedStartupFactAttribute : FactAttribute
{
    public GeneratedStartupFactAttribute()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || !Environment.Is64BitProcess ||
            RuntimeInformation.ProcessArchitecture != RuntimeInformation.OSArchitecture ||
            RuntimeInformation.ProcessArchitecture is not (Architecture.X64 or Architecture.Arm64))
            Skip = "Requires matching native Windows 11 x64 or ARM64; Mac compilation is not task-control acceptance.";
        else if (Environment.GetEnvironmentVariable(GeneratedStartupTaskFixture.OptInVariable) != "1")
            Skip = "Generated task registration/control is opt-in. Run scripts/windows/test-startup-fixtures.ps1 -RunGeneratedStartupFixtures.";
        // Do not time out a dispatched system operation while it retains the mutation lease.
    }
}

[CollectionDefinition("Generated startup fixtures", DisableParallelization = true)]
public sealed class GeneratedStartupCollection;

[Collection("Generated startup fixtures")]
public sealed class GeneratedStartupControlTests(ITestOutputHelper output)
{
    private sealed class Confirmation(GeneratedStartupTaskFixture fixture, bool accepted = true,
        Func<CancellationToken, Task>? duringConfirmation = null) : IStartupControlConfirmation
    {
        public int Requests { get; private set; }
        public async Task<bool> RequestAsync(StartupControlReview review, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            Assert.Equal(fixture.TaskPath, review.Task.TaskPath);
            Assert.Equal(fixture.OwnerSid, review.Task.ActorSid);
            Assert.True(review.CanChange);
            Requests++;
            if (duringConfirmation is not null) await duringConfirmation(token);
            return accepted;
        }
    }

    private sealed class TrackedMutation(GeneratedStartupTaskFixture fixture, Action? beforeDispatch = null) : IStartupControlMutation
    {
        private readonly WindowsStartupControlMutation native = new();
        public int Calls { get; private set; }
        public bool Available => native.Available;
        public async Task<StartupControlNativeResult> ApplyAsync(StartupControlReview review, DateTimeOffset expiry, CancellationToken token)
        {
            Assert.Equal(fixture.TaskPath, review.Task.TaskPath);
            Assert.Equal(fixture.OwnerSid, review.Task.ActorSid);
            await fixture.ObserveAsync();
            Calls++;
            beforeDispatch?.Invoke();
            return await native.ApplyAsync(review, expiry, token);
        }
    }

    private (WindowsRecordStore Store, StartupControlService Service, TrackedMutation Mutation) Prepare(
        GeneratedStartupTaskFixture fixture, Action? beforeDispatch = null)
    {
        output.WriteLine("Generated startup evidence: " + fixture.Root);
        Assert.False(WindowsStartupControlMutation.PublicExecutionAvailable);
        var store = new WindowsRecordStore(WindowsPath.Parse(Path.Combine(fixture.Root, "private-records")));
        Assert.Equal(fixture.OwnerSid, store.OwnerSid);
        var mutation = new TrackedMutation(fixture, beforeDispatch);
        return (store, new(store, fixture.Reviewer(), mutation, store.OwnerSid), mutation);
    }

    [GeneratedStartupFact]
    public async Task ExactGeneratedTaskRoundTripRecordsRealSwitchesAndCannotReplayOrLeakArguments()
    {
        await using var fixture = await GeneratedStartupTaskFixture.CreateAsync();
        var prepared = Prepare(fixture);
        var review = await fixture.Reviewer().InspectAsync(fixture.TaskPath, StartupControlAction.Enable);
        Assert.True(review.CanChange, string.Join(", ", review.BlockingReasons));
        // A saved review never grants execution or current confirmation.
        Assert.False(review.ExecutionAvailable);
        var confirmation = new Confirmation(fixture);
        var enabled = await prepared.Service.ExecuteAsync(review, confirmation);
        Assert.Equal(1, confirmation.Requests);
        Assert.Equal(1, prepared.Mutation.Calls);
        Assert.Equal(StartupControlState.Completed, enabled.State);
        Assert.Equal(StartupControlNativeOutcome.Applied, enabled.Result!.Outcome);
        Assert.True(enabled.Result.ObservedEnabled);
        Assert.True(enabled.Result.DefinitionMatches);
        Assert.True((await fixture.ObserveAsync()).Enabled);
        var bytes = await prepared.Store.ReadAsync(enabled.Id, StartupControlService.MaximumExecutionBytes, default);
        Assert.NotNull(bytes);
        Assert.DoesNotContain(fixture.PrivateArgument, System.Text.Encoding.UTF8.GetString(bytes));
        var reopened = new StartupControlService(prepared.Store, fixture.Reviewer(), new WindowsStartupControlMutation(), prepared.Store.OwnerSid);
        Assert.Equal(JsonSerializer.Serialize(enabled, ContractJson.Options), JsonSerializer.Serialize(await reopened.ShowAsync(enabled.Id), ContractJson.Options));
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => reopened.ExecuteAsync(review, confirmation))).Code);
        Assert.Equal(bytes, await prepared.Store.ReadAsync(enabled.Id, StartupControlService.MaximumExecutionBytes, default));
        Assert.Equal(1, confirmation.Requests);
        await fixture.SaveEvidenceAsync("enabled_and_replay_rejected", enabled);
        var disable = await fixture.Reviewer().InspectAsync(fixture.TaskPath, StartupControlAction.Disable);
        Assert.True(disable.CanChange);
        Assert.NotEqual(review.Id, disable.Id);
        var disabled = await prepared.Service.ExecuteAsync(disable, new Confirmation(fixture));
        Assert.Equal(StartupControlState.Completed, disabled.State);
        Assert.False(disabled.Result!.ObservedEnabled);
        Assert.False((await fixture.ObserveAsync()).Enabled);
        Assert.Equal(2, prepared.Mutation.Calls);
        await fixture.SaveEvidenceAsync("disabled", disabled);
    }

    [GeneratedStartupFact]
    public async Task DeclinedCurrentConfirmationLeavesGeneratedTaskAndNoIntent()
    {
        await using var fixture = await GeneratedStartupTaskFixture.CreateAsync();
        var prepared = Prepare(fixture);
        var review = await fixture.Reviewer().InspectAsync(fixture.TaskPath, StartupControlAction.Enable);
        var confirmation = new Confirmation(fixture, accepted: false);
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => prepared.Service.ExecuteAsync(review, confirmation))).Code);
        Assert.Equal(1, confirmation.Requests);
        Assert.Equal(0, prepared.Mutation.Calls);
        Assert.False((await fixture.ObserveAsync()).Enabled);
        Assert.Null(await prepared.Store.ReadAsync(review.Id, StartupControlService.MaximumExecutionBytes, default));
        await fixture.SaveEvidenceAsync("confirmation_declined", null);
    }

    [GeneratedStartupFact]
    public async Task DefinitionChangedDuringConfirmationPreventsMutationAndIntent()
    {
        await using var fixture = await GeneratedStartupTaskFixture.CreateAsync();
        var prepared = Prepare(fixture);
        var review = await fixture.Reviewer().InspectAsync(fixture.TaskPath, StartupControlAction.Enable);
        var confirmation = new Confirmation(fixture, duringConfirmation: _ => fixture.ChangeGeneratedDefinitionAsync());
        Assert.Equal("startup_changed", (await Assert.ThrowsAsync<ShouException>(() => prepared.Service.ExecuteAsync(review, confirmation))).Code);
        Assert.Equal(1, confirmation.Requests);
        Assert.Equal(0, prepared.Mutation.Calls);
        Assert.False((await fixture.ObserveAsync()).Enabled);
        Assert.Null(await prepared.Store.ReadAsync(review.Id, StartupControlService.MaximumExecutionBytes, default));
        await fixture.SaveEvidenceAsync("changed_definition_rejected", null);
    }

    [GeneratedStartupFact]
    public async Task StopDuringConfirmationCannotBecomeApproval()
    {
        await using var fixture = await GeneratedStartupTaskFixture.CreateAsync();
        var prepared = Prepare(fixture);
        var review = await fixture.Reviewer().InspectAsync(fixture.TaskPath, StartupControlAction.Enable);
        using var stop = new CancellationTokenSource();
        var confirmation = new Confirmation(fixture, duringConfirmation: _ => { stop.Cancel(); return Task.CompletedTask; });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => prepared.Service.ExecuteAsync(review, confirmation, stop.Token));
        Assert.Equal(0, prepared.Mutation.Calls);
        Assert.False((await fixture.ObserveAsync()).Enabled);
        Assert.Null(await prepared.Store.ReadAsync(review.Id, StartupControlService.MaximumExecutionBytes, default));
        await fixture.SaveEvidenceAsync("confirmation_cancelled", null);
    }

    [GeneratedStartupFact]
    public async Task DifferentActorAtNativeBoundaryCannotSetGeneratedTask()
    {
        await using var fixture = await GeneratedStartupTaskFixture.CreateAsync();
        output.WriteLine("Generated startup evidence: " + fixture.Root);
        var review = await fixture.Reviewer().InspectAsync(fixture.TaskPath, StartupControlAction.Enable);
        var forged = review with { Task = review.Task with { ActorSid = "S-1-0-0" } };
        var result = await new WindowsStartupControlMutation().ApplyAsync(forged, DateTimeOffset.UtcNow.AddSeconds(30), default);
        Assert.Equal(StartupControlNativeOutcome.NotStarted, result.Outcome);
        Assert.False((await fixture.ObserveAsync()).Enabled);
        await fixture.SaveEvidenceAsync("actor_mismatch_rejected", null);
    }

    [GeneratedStartupFact]
    public async Task StopAfterDurableIntentBeforeDispatchRecordsCancellationWithoutSettingTask()
    {
        await using var fixture = await GeneratedStartupTaskFixture.CreateAsync();
        using var stop = new CancellationTokenSource();
        var prepared = Prepare(fixture, stop.Cancel);
        var review = await fixture.Reviewer().InspectAsync(fixture.TaskPath, StartupControlAction.Enable);
        var result = await prepared.Service.ExecuteAsync(review, new Confirmation(fixture), stop.Token);
        Assert.Equal(1, prepared.Mutation.Calls);
        Assert.Equal(StartupControlState.Cancelled, result.State);
        Assert.Equal(StartupControlNativeOutcome.NotStarted, result.Result!.Outcome);
        Assert.False((await fixture.ObserveAsync()).Enabled);
        Assert.NotNull(await prepared.Store.ReadAsync(review.Id, StartupControlService.MaximumExecutionBytes, default));
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => prepared.Service.ExecuteAsync(review, new Confirmation(fixture)))).Code);
        await fixture.SaveEvidenceAsync("cancelled_after_intent", result);
    }
}
