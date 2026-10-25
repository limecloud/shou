using System.Runtime.InteropServices;
using Shou.Windows.Core;
using Xunit.Abstractions;

namespace Shou.Windows.Platform.Tests;

public sealed class GeneratedMsiFactAttribute : FactAttribute
{
    public GeneratedMsiFactAttribute()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || !Environment.Is64BitProcess ||
            RuntimeInformation.ProcessArchitecture != RuntimeInformation.OSArchitecture ||
            RuntimeInformation.ProcessArchitecture is not (Architecture.X64 or Architecture.Arm64))
            Skip = "Requires matching native Windows 11 x64 or ARM64; host compilation is not installer acceptance.";
        else if (Environment.GetEnvironmentVariable(GeneratedMsiFixture.OptInVariable) != "1")
            Skip = "Generated MSI installation/uninstallation is opt-in. Run scripts/windows/test-uninstall-fixtures.ps1 -RunGeneratedMsiFixtures.";
        // A test-runner timeout must not abandon a running system installer or its domain lease.
    }
}

[CollectionDefinition("Generated MSI fixtures", DisableParallelization = true)]
public sealed class GeneratedMsiCollection;

[Collection("Generated MSI fixtures")]
public sealed class GeneratedMsiUninstallTests(ITestOutputHelper output)
{
    private sealed class Confirmation(GeneratedMsiFixture fixture, bool accepted) : IApplicationUninstallConfirmation
    {
        public int Requests { get; private set; }
        public Task<bool> RequestAsync(ApplicationUninstallPlan plan, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Assert.Equal(fixture.ProductCode, plan.Review.Installation.Identity!.SystemId);
            Assert.Equal(fixture.PackageCode, plan.Review.Installation.Identity.PackageCode);
            Assert.Equal(fixture.OwnerSid, plan.OwnerSid);
            Assert.Equal(fixture.ProductName, plan.Review.Installation.Name);
            Assert.True(plan.Review.Installation.InstalledRoot!.Path.SamePath(WindowsPath.Parse(fixture.InstallDirectory)));
            Requests++;
            return Task.FromResult(accepted);
        }
    }

    private sealed class TrackedMutation : IApplicationUninstallMutation
    {
        private readonly WindowsApplicationUninstallMutation native = new();
        public int Calls { get; private set; }
        public bool Supports(ApplicationInstallerKind kind) => native.Supports(kind);
        public Task<ApplicationUninstallResult> ApplyAsync(ApplicationUninstallReview review, string ownerSid,
            DateTimeOffset authorizationExpiresAt, CancellationToken cancellationToken)
        {
            Calls++;
            return native.ApplyAsync(review, ownerSid, authorizationExpiresAt, cancellationToken);
        }
    }

    private static ApplicationUninstallReviewer Reviewer() => new(new(new WindowsApplicationInventory()),
        new WindowsApplicationUninstallInspector(), new WindowsApplicationActivity());

    private async Task<(ApplicationUninstallPlan Plan, WindowsRecordStore Store, ApplicationUninstallService Service, TrackedMutation Mutation)> PrepareAsync(GeneratedMsiFixture fixture)
    {
        output.WriteLine("Generated MSI evidence: " + fixture.Root);
        Assert.False(WindowsApplicationUninstallMutation.PublicExecutionAvailable);
        var application = await fixture.DiscoverAsync();
        var reviewer = Reviewer();
        var review = await reviewer.InspectAsync(application.Id);
        Assert.True(review.CanPreparePlan, string.Join(", ", review.BlockingReasons));
        Assert.Equal(MsiInstallationContext.UserUnmanaged, review.Installation.Identity!.Context);
        Assert.Equal(fixture.OwnerSid, review.Installation.Identity.UserSid);
        var store = new WindowsRecordStore(WindowsPath.Parse(Path.Combine(fixture.Root, "private-records")));
        var plan = await new ApplicationUninstallPlanner(store, reviewer, store.OwnerSid).CreateAsync(application.Id, review.Digest, true);
        var mutation = new TrackedMutation();
        return (plan, store, new(store, reviewer, store.OwnerSid, mutation), mutation);
    }

    [GeneratedMsiFact]
    public async Task ExactGeneratedMsiUninstallRecordsRealOutcomeAndKeepsUnregisteredDataWithoutReplay()
    {
        await using var fixture = await GeneratedMsiFixture.InstallAsync();
        var prepared = await PrepareAsync(fixture);
        var confirmation = new Confirmation(fixture, accepted: true);
        var consent = await prepared.Service.ConfirmAsync(prepared.Plan.Id, confirmation);
        Assert.Equal(1, confirmation.Requests);
        var execution = await prepared.Service.ExecuteAsync(prepared.Plan.Id, consent);
        Assert.Equal(1, prepared.Mutation.Calls);
        Assert.Equal(ApplicationUninstallState.Completed, execution.State);
        Assert.Equal(SystemUninstallOutcome.Succeeded, execution.Result!.Outcome);
        Assert.Equal(InstallationPresence.Absent, execution.Result.Presence);
        Assert.False(execution.Result.RestartRequired);
        Assert.Null(fixture.InstalledState());
        fixture.AssertGeneratedBytes(installed: false);
        var before = await prepared.Store.ReadAsync(execution.Id, ApplicationUninstallService.MaximumExecutionBytes, default);
        Assert.NotNull(before);
        var reopened = new ApplicationUninstallService(prepared.Store, Reviewer(), prepared.Store.OwnerSid, new WindowsApplicationUninstallMutation());
        Assert.Equal(execution, await reopened.ShowAsync(prepared.Plan.Id));
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => prepared.Service.ExecuteAsync(prepared.Plan.Id, consent))).Code);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => reopened.ConfirmAsync(prepared.Plan.Id, confirmation))).Code);
        Assert.Equal(before, await prepared.Store.ReadAsync(execution.Id, ApplicationUninstallService.MaximumExecutionBytes, default));
        Assert.Equal(1, prepared.Mutation.Calls);
        fixture.SaveEvidence("service_completed", execution);
    }

    [GeneratedMsiFact]
    public async Task DeclinedCurrentConfirmationLeavesGeneratedInstallationAndNoExecutionIntent()
    {
        await using var fixture = await GeneratedMsiFixture.InstallAsync();
        var prepared = await PrepareAsync(fixture);
        var confirmation = new Confirmation(fixture, accepted: false);
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => prepared.Service.ConfirmAsync(prepared.Plan.Id, confirmation))).Code);
        Assert.Equal(1, confirmation.Requests);
        Assert.Equal(0, prepared.Mutation.Calls);
        Assert.Equal("5", fixture.InstalledState());
        Assert.Null(await prepared.Store.ReadAsync(ApplicationUninstallService.ExecutionId(prepared.Plan.Id), ApplicationUninstallService.MaximumExecutionBytes, default));
        fixture.AssertGeneratedBytes(installed: true);
        fixture.SaveEvidence("confirmation_declined", null);
    }

    [GeneratedMsiFact]
    public async Task RemovedInstallationAfterConfirmationCannotDispatchOrPersistAnUninstallIntent()
    {
        await using var fixture = await GeneratedMsiFixture.InstallAsync();
        var prepared = await PrepareAsync(fixture);
        var consent = await prepared.Service.ConfirmAsync(prepared.Plan.Id, new Confirmation(fixture, accepted: true));
        await fixture.RemoveOwnedInstallationAsync();
        var error = await Assert.ThrowsAsync<ShouException>(() => prepared.Service.ExecuteAsync(prepared.Plan.Id, consent));
        Assert.Contains(error.Code, new[] { "not_found", "application_changed", "application_discovery_incomplete" });
        Assert.Equal(0, prepared.Mutation.Calls);
        Assert.Null(await prepared.Store.ReadAsync(ApplicationUninstallService.ExecutionId(prepared.Plan.Id), ApplicationUninstallService.MaximumExecutionBytes, default));
        fixture.AssertGeneratedBytes(installed: false);
        fixture.SaveEvidence("changed_preflight_rejected", null);
    }

    [GeneratedMsiFact]
    public async Task DifferentActorAtNativeBoundaryCannotChangeTheGeneratedInstallation()
    {
        await using var fixture = await GeneratedMsiFixture.InstallAsync();
        output.WriteLine("Generated MSI evidence: " + fixture.Root);
        var application = await fixture.DiscoverAsync();
        var review = await Reviewer().InspectAsync(application.Id);
        Assert.True(review.CanPreparePlan, string.Join(", ", review.BlockingReasons));
        var result = await new WindowsApplicationUninstallMutation().ApplyAsync(review, "S-1-0-0", DateTimeOffset.UtcNow.AddMinutes(1), default);
        Assert.Equal(SystemUninstallOutcome.NotStarted, result.Outcome);
        Assert.Equal("installation_user_changed", result.Reason);
        Assert.Equal("5", fixture.InstalledState());
        fixture.AssertGeneratedBytes(installed: true);
        fixture.SaveEvidence("actor_change_rejected", null);
    }

    [GeneratedMsiFact]
    public async Task LockedGeneratedPayloadPreventsPlanningAndKeepsEveryFixtureByte()
    {
        await using var fixture = await GeneratedMsiFixture.InstallAsync();
        output.WriteLine("Generated MSI evidence: " + fixture.Root);
        var application = await fixture.DiscoverAsync();
        var reviewer = Reviewer();
        using (var held = new FileStream(fixture.InstalledPayload, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var review = await reviewer.InspectAsync(application.Id);
            Assert.Equal(ActivityState.Active, review.Activity.State);
            Assert.False(review.CanPreparePlan);
            var store = new WindowsRecordStore(WindowsPath.Parse(Path.Combine(fixture.Root, "private-records")));
            Assert.Equal("unsupported_capability", (await Assert.ThrowsAsync<ShouException>(() => new ApplicationUninstallPlanner(store,
                reviewer, store.OwnerSid).CreateAsync(application.Id, review.Digest, true))).Code);
            Assert.False(Directory.Exists(store.Directory.Value));
            fixture.AssertGeneratedBytes(installed: true);
        }
        fixture.SaveEvidence("active_installation_rejected", null);
    }
}
