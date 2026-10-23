using System.Collections.Immutable;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class ApplicationUninstallExecutionTests
{
    private const string Sid = "S-1-5-21-1000";
    private const string Product = "{00000000-0000-0000-0000-000000000001}";
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-23T00:00:00Z");
    private sealed class Clock : TimeProvider { public DateTimeOffset Now = ApplicationUninstallExecutionTests.Now; public override DateTimeOffset GetUtcNow() => Now; }
    private sealed class Fixture : IApplicationInventory, IApplicationUninstallInspector, IApplicationUninstallActivity, IApplicationUninstallMutation, IApplicationUninstallConfirmation
    {
        public readonly MemoryRecordStore Store = new();
        public readonly Clock Clock = new();
        public ApplicationRegistration Registration = new(ApplicationSource.CurrentUserRegistry, Product, "Example", "1.0", "Publisher", UsesWindowsInstaller: true);
        public ApplicationUninstallObservation Installation = new(new(ApplicationInstallerKind.Msi, Product, MsiInstallationContext.UserUnmanaged, Sid,
            "{00000000-0000-0000-0000-000000000002}"), "Example", "1.0", "Publisher",
            new(WindowsPath.Parse("C:/Example"), new(1, new string('1', 32), Sid), EntryKind.Directory, 0, 0, Now, Now), false, []);
        public ActivityObservation Activity = new(ActivityState.Idle, "no_observed_installation_users");
        public ApplicationUninstallResult Result = new(SystemUninstallOutcome.Succeeded, InstallationPresence.Absent, 0);
        public bool Supported = true;
        public bool Confirm = true;
        public int Mutations;
        public int Confirmations;
        public Action? DuringConfirmation;
        public Action? DuringInspection;
        public Func<Task>? DuringMutation;
        public ApplicationUninstallReviewer Reviewer => new(new(this, Clock), this, this, Clock);
        public ApplicationUninstallService Service { get; }
        public Fixture() => Service = NewService();
        public ApplicationUninstallService NewService() => new(Store, Reviewer, Sid, this, Clock);
        public async Task<ApplicationUninstallPlan> PlanAsync()
        {
            var id = ApplicationCatalog.ApplicationId(Registration.Source, Registration.RegistrationKey);
            var review = await Reviewer.InspectAsync(id);
            return await new ApplicationUninstallPlanner(Store, Reviewer, Sid, Clock).CreateAsync(id, review.Digest, true);
        }
        public Task<ApplicationInventory> ReadAsync(ApplicationDiscoveryBudget budget, CancellationToken cancellationToken) => Task.FromResult(new ApplicationInventory(
            [Registration], Enum.GetValues<ApplicationSource>().Select(source => new ApplicationSourceCoverage(source, ApplicationSourceState.Complete,
                source == Registration.Source ? 1 : 0, [])).ToImmutableArray()));
        public Task<ApplicationUninstallObservation> InspectAsync(InstalledApplication application, CancellationToken cancellationToken)
        { DuringInspection?.Invoke(); return Task.FromResult(Installation); }
        public Task<ActivityObservation> InspectAsync(ApplicationUninstallObservation installation, CancellationToken cancellationToken) => Task.FromResult(Activity);
        public bool Supports(ApplicationInstallerKind kind) => Supported;
        public Task<bool> RequestAsync(ApplicationUninstallPlan plan, CancellationToken cancellationToken)
        { Confirmations++; DuringConfirmation?.Invoke(); return Task.FromResult(Confirm); }
        public async Task<ApplicationUninstallResult> ApplyAsync(ApplicationUninstallReview review, string ownerSid, DateTimeOffset authorizationExpiresAt, CancellationToken cancellationToken)
        {
            Mutations++;
            Assert.Equal(Sid, ownerSid);
            Assert.InRange(authorizationExpiresAt - Clock.Now, TimeSpan.FromTicks(1), TimeSpan.FromMinutes(1));
            var intent = Assert.Single(Store.Records, pair => pair.Key.StartsWith("uninstall_execution_", StringComparison.Ordinal));
            Assert.Equal("uninstalling", JsonNode.Parse(intent.Value)!["state"]!.GetValue<string>());
            Assert.Equal(Installation.Identity, review.Installation.Identity);
            if (DuringMutation is not null) await DuringMutation();
            return Result;
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ExactMsiOrMsixPlanRequiresCurrentConfirmationAndRecordsIndependentFacts(bool msix)
    {
        var fixture = new Fixture();
        if (msix)
        {
            fixture.Registration = new(ApplicationSource.CurrentUserMsix, "Example_1.0.0.0_x64__publisher", "Example");
            fixture.Installation = fixture.Installation with { Identity = new(ApplicationInstallerKind.Msix, fixture.Registration.RegistrationKey,
                MsiInstallationContext.None, Sid, PackageFamilyName: "Example_publisher") };
        }
        var plan = await fixture.PlanAsync();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, fixture);
        Assert.Single(fixture.Store.Records);
        var execution = await fixture.Service.ExecuteAsync(plan.Id, consent);
        Assert.Equal(ApplicationUninstallState.Completed, execution.State);
        Assert.Equal(SystemUninstallOutcome.Succeeded, execution.Result!.Outcome);
        Assert.Equal(InstallationPresence.Absent, execution.Result.Presence);
        Assert.Equal(execution, await fixture.Service.ShowAsync(plan.Id));
        Assert.False(execution.RetryAvailable);
        Assert.False(execution.RestoreAvailable);
        Assert.False(execution.ObservationRequired);
        Assert.Equal(1, fixture.Mutations);
    }

    [Fact]
    public async Task PreparedPlanOrDeclinedPromptDoesNotAuthorizeAnInstaller()
    {
        var fixture = new Fixture { Confirm = false };
        var plan = await fixture.PlanAsync();
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, null))).Code);
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ConfirmAsync(plan.Id, fixture))).Code);
        Assert.Equal(0, fixture.Mutations);
        Assert.Single(fixture.Store.Records);
    }

    [Fact]
    public async Task ConfirmationBelongsToOneServiceAndCannotBeReplayedAfterARealOutcome()
    {
        var fixture = new Fixture();
        var plan = await fixture.PlanAsync();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, fixture);
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => fixture.NewService().ExecuteAsync(plan.Id, consent))).Code);
        await fixture.Service.ExecuteAsync(plan.Id, consent);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent))).Code);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => fixture.NewService().ConfirmAsync(plan.Id, fixture))).Code);
        Assert.Equal(1, fixture.Mutations);
    }

    [Theory]
    [InlineData(60, "confirmation_required")]
    [InlineData(900, "plan_stale")]
    [InlineData(-1, "plan_stale")]
    public async Task ExpiredConfirmationPlanOrClockRollbackCannotExecute(int seconds, string code)
    {
        var fixture = new Fixture();
        var plan = await fixture.PlanAsync();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, fixture);
        fixture.Clock.Now += TimeSpan.FromSeconds(seconds);
        Assert.Equal(code, (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent))).Code);
        Assert.Equal(0, fixture.Mutations);
        Assert.Single(fixture.Store.Records);
    }

    [Fact]
    public async Task ConfirmationExpiringDuringExecutionPreflightCannotStartAnInstaller()
    {
        var fixture = new Fixture();
        var plan = await fixture.PlanAsync();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, fixture);
        fixture.DuringInspection = () => fixture.Clock.Now += TimeSpan.FromMinutes(1);
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent))).Code);
        Assert.Equal(0, fixture.Mutations);
        Assert.Single(fixture.Store.Records);
    }

    [Fact]
    public async Task PromptCannotConfirmAfterPlanExpiryOrCallerCancellation()
    {
        var fixture = new Fixture();
        var plan = await fixture.PlanAsync();
        fixture.DuringConfirmation = () => fixture.Clock.Now += TimeSpan.FromMinutes(15);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ConfirmAsync(plan.Id, fixture))).Code);
        fixture.Clock.Now = Now;
        using var cancelled = new CancellationTokenSource();
        fixture.DuringConfirmation = cancelled.Cancel;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Service.ConfirmAsync(plan.Id, fixture, cancelled.Token));
        Assert.Single(fixture.Store.Records);
    }

    [Theory]
    [InlineData("active")]
    [InlineData("unknown")]
    [InlineData("identity")]
    [InlineData("directory")]
    public async Task ChangedActivityOrInstallationAfterConfirmationPreventsIntentAndConsumesThatConsent(string change)
    {
        var fixture = new Fixture();
        var plan = await fixture.PlanAsync();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, fixture);
        var installation = fixture.Installation;
        if (change is "active" or "unknown") fixture.Activity = new(change == "active" ? ActivityState.Active : ActivityState.Unknown, "fixture");
        else if (change == "identity") fixture.Installation = installation with { Identity = installation.Identity! with { PackageCode = Product } };
        else fixture.Installation = installation with { InstalledRoot = installation.InstalledRoot! with { Identity = new(1, new string('2', 32), Sid) } };
        Assert.Equal("application_changed", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent))).Code);
        fixture.Installation = installation;
        fixture.Activity = new(ActivityState.Idle, "no_observed_installation_users");
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent))).Code);
        Assert.Single(fixture.Store.Records);
        Assert.Equal(0, fixture.Mutations);
    }

    [Fact]
    public async Task ChangedActivityOrUnavailableAdapterPreventsEvenTheConfirmationPrompt()
    {
        var fixture = new Fixture();
        var plan = await fixture.PlanAsync();
        fixture.Activity = new(ActivityState.Active, "fixture");
        Assert.Equal("application_changed", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ConfirmAsync(plan.Id, fixture))).Code);
        fixture.Supported = false;
        Assert.Equal("unsupported_capability", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ConfirmAsync(plan.Id, fixture))).Code);
        Assert.Equal(0, fixture.Confirmations);
    }

    [Fact]
    public async Task FailedIntentPublicationNeverInvokesTheInstaller()
    {
        var fixture = new Fixture();
        var plan = await fixture.PlanAsync();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, fixture);
        fixture.Store.FailWrite = true;
        var error = await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent));
        Assert.Equal("journal_write_failed", error.Code);
        Assert.Contains("No installer was invoked", error.Message);
        Assert.Equal(0, fixture.Mutations);
        Assert.Single(fixture.Store.Records);
    }

    [Fact]
    public async Task FailedOutcomePublicationRetainsUnresolvedIntentAndBlocksReexecution()
    {
        var fixture = new Fixture();
        var plan = await fixture.PlanAsync();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, fixture);
        fixture.Store.FailPublication = (_, bytes) => JsonNode.Parse(bytes)!["state"]?.GetValue<string>() == "completed";
        var error = await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent));
        Assert.Equal("journal_write_failed", error.Code);
        Assert.Contains("may have changed", error.Message);
        var saved = await fixture.Service.ShowAsync(plan.Id);
        Assert.Equal(ApplicationUninstallState.Uninstalling, saved.State);
        Assert.Null(saved.Result);
        Assert.True(saved.ObservationRequired);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => fixture.NewService().ConfirmAsync(plan.Id, fixture))).Code);
        Assert.Equal(1, fixture.Mutations);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ExceptionAfterIntentNeverClaimsNoChangesOrRetries(bool cancelled)
    {
        var fixture = new Fixture { DuringMutation = () => cancelled ? throw new OperationCanceledException() : throw new IOException("fixture") };
        var plan = await fixture.PlanAsync();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, fixture);
        var execution = await fixture.Service.ExecuteAsync(plan.Id, consent);
        Assert.Equal(ApplicationUninstallState.Unknown, execution.State);
        Assert.Equal(InstallationPresence.Unknown, execution.Result!.Presence);
        Assert.True(execution.ObservationRequired);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => fixture.NewService().ConfirmAsync(plan.Id, fixture))).Code);
    }

    [Fact]
    public async Task CallerCancellationDuringAnInstallerKeepsTheLeaseAndRecordsTheRealOutcome()
    {
        var fixture = new Fixture();
        using var cancelled = new CancellationTokenSource();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.DuringMutation = async () => { entered.SetResult(); await finish.Task; };
        var plan = await fixture.PlanAsync();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, fixture);
        var running = fixture.Service.ExecuteAsync(plan.Id, consent, cancelled.Token);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            cancelled.Cancel();
            Assert.False(running.IsCompleted);
            Assert.Equal("store_busy", (await Assert.ThrowsAsync<ShouException>(() => fixture.Store.AcquireLeaseAsync(default))).Code);
        }
        finally { finish.TrySetResult(); }
        Assert.Equal(ApplicationUninstallState.Completed, (await running).State);
        Assert.Equal(ApplicationUninstallState.Completed, (await fixture.Service.ShowAsync(plan.Id)).State);
    }

    [Fact]
    public async Task CancellationAtIntentPublicationRecordsNotStartedAndDoesNotDispatchAnInstaller()
    {
        var fixture = new Fixture();
        using var cancelled = new CancellationTokenSource();
        var plan = await fixture.PlanAsync();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, fixture);
        fixture.Store.FailPublication = (_, _) => { cancelled.Cancel(); return false; };
        var execution = await fixture.Service.ExecuteAsync(plan.Id, consent, cancelled.Token);
        Assert.Equal(ApplicationUninstallState.Cancelled, execution.State);
        Assert.Equal(SystemUninstallOutcome.NotStarted, execution.Result!.Outcome);
        Assert.Equal(0, fixture.Mutations);
    }

    [Theory]
    [InlineData(SystemUninstallOutcome.Succeeded, InstallationPresence.Absent, ApplicationUninstallState.Completed)]
    [InlineData(SystemUninstallOutcome.Succeeded, InstallationPresence.Present, ApplicationUninstallState.Unknown)]
    [InlineData(SystemUninstallOutcome.Succeeded, InstallationPresence.Changed, ApplicationUninstallState.Unknown)]
    [InlineData(SystemUninstallOutcome.Succeeded, InstallationPresence.Unknown, ApplicationUninstallState.Unknown)]
    [InlineData(SystemUninstallOutcome.Failed, InstallationPresence.Absent, ApplicationUninstallState.Failed)]
    [InlineData(SystemUninstallOutcome.Cancelled, InstallationPresence.Present, ApplicationUninstallState.Cancelled)]
    [InlineData(SystemUninstallOutcome.Unknown, InstallationPresence.Absent, ApplicationUninstallState.Unknown)]
    [InlineData(SystemUninstallOutcome.NotStarted, InstallationPresence.Unknown, ApplicationUninstallState.Failed)]
    public async Task InstallerReportsAndIdentityPresenceCannotSubstituteForEachOther(SystemUninstallOutcome outcome, InstallationPresence presence, ApplicationUninstallState expected)
    {
        var fixture = new Fixture { Result = new(outcome, presence) };
        var plan = await fixture.PlanAsync();
        var execution = await fixture.Service.ExecuteAsync(plan.Id, await fixture.Service.ConfirmAsync(plan.Id, fixture));
        Assert.Equal(expected, execution.State);
        Assert.Equal(outcome, execution.Result!.Outcome);
        Assert.Equal(presence, execution.Result.Presence);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("enum")]
    [InlineData("reason")]
    [InlineData("restart")]
    public async Task InvalidAdapterResultsRemainUnknown(string field)
    {
        var fixture = new Fixture { Result = field switch
        {
            "null" => null!, "enum" => new((SystemUninstallOutcome)99, InstallationPresence.Absent),
            "reason" => new(SystemUninstallOutcome.Succeeded, InstallationPresence.Absent, Reason: "bad\nreason"),
            _ => new(SystemUninstallOutcome.Failed, InstallationPresence.Absent, RestartRequired: true)
        } };
        var plan = await fixture.PlanAsync();
        Assert.Equal(ApplicationUninstallState.Unknown, (await fixture.Service.ExecuteAsync(plan.Id, await fixture.Service.ConfirmAsync(plan.Id, fixture))).State);
    }

    [Theory]
    [InlineData("plan_id")]
    [InlineData("plan_digest")]
    [InlineData("owner_sid")]
    [InlineData("state")]
    [InlineData("result")]
    [InlineData("time")]
    [InlineData("unknown_field")]
    public async Task CorruptOrUnboundExecutionCannotBecomeAValidHistoryResult(string field)
    {
        var fixture = new Fixture();
        var plan = await fixture.PlanAsync();
        var execution = await fixture.Service.ExecuteAsync(plan.Id, await fixture.Service.ConfirmAsync(plan.Id, fixture));
        var json = JsonNode.Parse(fixture.Store.Records[execution.Id])!;
        switch (field)
        {
            case "plan_id": json[field] = "uninstall_plan_" + new string('0', 32); break;
            case "plan_digest": json[field] = "sha256:" + new string('0', 64); break;
            case "owner_sid": json[field] = "S-1-5-21-9999"; break;
            case "state": json[field] = "uninstalling"; break;
            case "result": json[field]!["presence"] = "present"; break;
            case "time": json["updated_at"] = Now - TimeSpan.FromSeconds(1); break;
            default: json["approved"] = true; break;
        }
        fixture.Store.Records[execution.Id] = JsonSerializer.SerializeToUtf8Bytes(json);
        Assert.Equal("corrupt_record", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ShowAsync(plan.Id))).Code);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => fixture.NewService().ConfirmAsync(plan.Id, fixture))).Code);
    }

    [Fact]
    public async Task HistoryOfMissingExecutionDoesNotCreateAnIntent()
    {
        var fixture = new Fixture();
        var plan = await fixture.PlanAsync();
        Assert.Equal("not_found", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ShowAsync(plan.Id))).Code);
        Assert.Single(fixture.Store.Records);
        Assert.Equal(0, fixture.Mutations);
    }
}
