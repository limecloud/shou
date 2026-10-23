using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class ApplicationUninstallTests
{
    private const string Sid = "S-1-5-21-1000";
    private const string Product = "{00000000-0000-0000-0000-000000000001}";
    private const string Package = "{00000000-0000-0000-0000-000000000002}";
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-23T00:00:00Z");
    private sealed class Clock : TimeProvider { public DateTimeOffset Now { get; set; } = ApplicationUninstallTests.Now; public override DateTimeOffset GetUtcNow() => Now; }
    private sealed class Fixture : IApplicationInventory, IApplicationUninstallInspector, IApplicationUninstallActivity
    {
        public readonly MemoryRecordStore Store = new();
        public readonly Clock Clock = new();
        public ApplicationRegistration Registration = new(ApplicationSource.CurrentUserRegistry, Product, "Example", "1.0", "Publisher", UsesWindowsInstaller: true);
        public ApplicationUninstallObservation Observation = new(new(ApplicationInstallerKind.Msi, Product, MsiInstallationContext.UserUnmanaged, Sid, Package),
            "Example", "1.0", "Publisher", new(WindowsPath.Parse("C:/Example"), new(1, new string('1', 32), Sid), EntryKind.Directory, 0, 0, Now, Now), false, []);
        public int Inspections;
        public bool Partial;
        public ActivityObservation Activity = new(ActivityState.Idle, "no_observed_installation_users");
        public ApplicationUninstallReviewer Reviewer => new(new(this, Clock), this, this, Clock);
        public ApplicationUninstallPlanner Planner => new(Store, Reviewer, Sid, Clock);
        public string Id => ApplicationCatalog.ApplicationId(Registration.Source, Registration.RegistrationKey);
        public Task<ApplicationInventory> ReadAsync(ApplicationDiscoveryBudget budget, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(new ApplicationInventory([Registration], Enum.GetValues<ApplicationSource>().Select(source => new ApplicationSourceCoverage(source,
                Partial ? ApplicationSourceState.Partial : ApplicationSourceState.Complete, source == Registration.Source ? 1 : 0,
                Partial ? ["entry_limit"] : [])).ToImmutableArray()));
        }
        public Task<ApplicationUninstallObservation> InspectAsync(InstalledApplication application, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); Inspections++; return Task.FromResult(Observation); }
        public Task<ActivityObservation> InspectAsync(ApplicationUninstallObservation installation, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); return Task.FromResult(Activity); }
        public async Task<ApplicationUninstallPlan> CreateAsync()
        {
            var review = await Reviewer.InspectAsync(Id);
            return await Planner.CreateAsync(Id, review.Digest, true);
        }
    }

    [Fact]
    public async Task MsiReviewUsesExactSystemIdentityWithoutGrantingExecutionOrCreatingStorage()
    {
        var fixture = new Fixture();
        var review = await fixture.Reviewer.InspectAsync(fixture.Id);
        Assert.True(review.CanPreparePlan);
        Assert.False(review.ExecutionAvailable);
        Assert.Equal(Product, review.Installation.Identity!.SystemId);
        Assert.Contains("installer_managed_data_may_be_removed", review.Warnings);
        Assert.Equal(ActivityState.Idle, review.Activity.State);
        Assert.Contains("activity_covers_installation_directory_only", review.Warnings);
        Assert.Empty(fixture.Store.Records);
    }

    [Fact]
    public async Task MsixReviewBindsCurrentUserPackageAndDisclosesSystemDependencyRemoval()
    {
        var fixture = new Fixture();
        fixture.Registration = new(ApplicationSource.CurrentUserMsix, "Example_1.0.0.0_x64__publisher", "Example");
        fixture.Observation = new(new(ApplicationInstallerKind.Msix, fixture.Registration.RegistrationKey, MsiInstallationContext.None, Sid,
            PackageFamilyName: "Example_publisher"), "Example", "1.0.0.0", "Publisher", fixture.Observation.InstalledRoot, false, []);
        var review = await fixture.Reviewer.InspectAsync(fixture.Id);
        Assert.True(review.CanPreparePlan);
        Assert.Contains("windows_may_remove_unused_package_dependencies", review.Warnings);
        Assert.Equal("Example_publisher", review.Installation.Identity!.PackageFamilyName);
    }

    [Theory]
    [InlineData("unsupported_installer")]
    [InlineData("ambiguous_installer_context")]
    [InlineData("installer_registration_mismatch")]
    [InlineData("application_inspection_time_limit")]
    public async Task MissingSystemIdentityHasAnExplicitBlockingReason(string reason)
    {
        var fixture = new Fixture { Observation = new(null, null, null, null, null, false, [reason]) };
        var review = await fixture.Reviewer.InspectAsync(fixture.Id);
        Assert.False(review.CanPreparePlan);
        Assert.Contains(reason, review.BlockingReasons);
        Assert.Equal("unsupported_capability", (await Assert.ThrowsAsync<ShouException>(() => fixture.Planner.CreateAsync(fixture.Id, review.Digest, true))).Code);
        Assert.Empty(fixture.Store.Records);
    }

    [Fact]
    public async Task ProtectedAndCurrentApplicationFactsPreventPlanning()
    {
        var fixture = new Fixture();
        fixture.Observation = fixture.Observation with { IsProtected = true };
        var review = await fixture.Reviewer.InspectAsync(fixture.Id);
        Assert.Contains("protected_application", review.BlockingReasons);
        Assert.False(review.CanPreparePlan);
        await Assert.ThrowsAsync<ShouException>(() => fixture.Planner.CreateAsync(fixture.Id, review.Digest, true));
    }

    [Theory]
    [InlineData("wrong_product")]
    [InlineData("wrong_context")]
    [InlineData("missing_package_code")]
    [InlineData("control_text")]
    [InlineData("invalid_directory")]
    public async Task MismatchedOrMalformedSystemFactsAreRejected(string mutation)
    {
        var fixture = new Fixture();
        var observation = fixture.Observation;
        fixture.Observation = mutation switch
        {
            "wrong_product" => observation with { Identity = observation.Identity! with { SystemId = Package } },
            "wrong_context" => observation with { Identity = observation.Identity! with { Context = MsiInstallationContext.Machine, UserSid = null } },
            "missing_package_code" => observation with { Identity = observation.Identity! with { PackageCode = null } },
            "control_text" => observation with { Name = "Example\u001b[31m" },
            _ => observation with { InstalledRoot = new(WindowsPath.Parse("C:/Example"), new(1, new string('1', 32), Sid), EntryKind.File, 1, 1, Now, Now) }
        };
        Assert.Equal("application_inspection_invalid", (await Assert.ThrowsAsync<ShouException>(() => fixture.Reviewer.InspectAsync(fixture.Id))).Code);
        Assert.Empty(fixture.Store.Records);
    }

    [Fact]
    public async Task ReviewDigestIsStableAcrossObservationTimesAndChangesWithInstallationIdentity()
    {
        var fixture = new Fixture();
        var first = await fixture.Reviewer.InspectAsync(fixture.Id);
        fixture.Clock.Now += TimeSpan.FromSeconds(1);
        var second = await fixture.Reviewer.InspectAsync(fixture.Id);
        Assert.Equal(first.Digest, second.Digest);
        Assert.NotEqual(first.ObservedAt, second.ObservedAt);
        fixture.Observation = fixture.Observation with { Identity = fixture.Observation.Identity! with { PackageCode = "{00000000-0000-0000-0000-000000000003}" } };
        Assert.NotEqual(first.Digest, (await fixture.Reviewer.InspectAsync(fixture.Id)).Digest);
    }

    [Fact]
    public async Task InstallerDataAcknowledgementIsRequiredBeforeReinspectionAndPersistence()
    {
        var fixture = new Fixture();
        var error = await Assert.ThrowsAsync<ShouException>(() => fixture.Planner.CreateAsync(fixture.Id, "sha256:" + new string('0', 64), false));
        Assert.Equal("installer_data_consent_required", error.Code);
        Assert.Equal(0, fixture.Inspections);
        Assert.Equal(0, fixture.Store.Writes);
    }

    [Fact]
    public async Task ChangedInstallationCannotReuseAnEarlierReviewDigest()
    {
        var fixture = new Fixture();
        var review = await fixture.Reviewer.InspectAsync(fixture.Id);
        fixture.Observation = fixture.Observation with { Version = "2.0" };
        var error = await Assert.ThrowsAsync<ShouException>(() => fixture.Planner.CreateAsync(fixture.Id, review.Digest, true));
        Assert.Equal("application_changed", error.Code);
        Assert.Empty(fixture.Store.Records);
    }

    [Theory]
    [InlineData(ActivityState.Active, "application_running")]
    [InlineData(ActivityState.Unknown, "application_activity_unknown")]
    public async Task ActiveOrUnknownInstallationCannotProduceAPlan(ActivityState state, string reason)
    {
        var fixture = new Fixture { Activity = new(state, "fixture_activity") };
        var review = await fixture.Reviewer.InspectAsync(fixture.Id);
        Assert.Contains(reason, review.BlockingReasons);
        Assert.False(review.CanPreparePlan);
        Assert.Equal("unsupported_capability", (await Assert.ThrowsAsync<ShouException>(() => fixture.Planner.CreateAsync(fixture.Id, review.Digest, true))).Code);
        Assert.Empty(fixture.Store.Records);
    }

    [Fact]
    public async Task ApplicationStartingAfterReviewInvalidatesTheReviewedDigest()
    {
        var fixture = new Fixture();
        var review = await fixture.Reviewer.InspectAsync(fixture.Id);
        fixture.Activity = new(ActivityState.Active, "application_process_running");
        Assert.Equal("application_changed", (await Assert.ThrowsAsync<ShouException>(() => fixture.Planner.CreateAsync(fixture.Id, review.Digest, true))).Code);
        Assert.Empty(fixture.Store.Records);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("enum")]
    [InlineData("missing_reason")]
    [InlineData("invalid_reason")]
    public async Task InvalidActivityObservationsCannotBecomeAnEligibleReview(string issue)
    {
        var fixture = new Fixture { Activity = issue switch
        {
            "null" => null!,
            "enum" => new((ActivityState)99, "fixture"),
            "missing_reason" => new(ActivityState.Idle),
            _ => new(ActivityState.Idle, "not a reason\n")
        } };
        Assert.Equal("application_inspection_invalid", (await Assert.ThrowsAsync<ShouException>(() => fixture.Reviewer.InspectAsync(fixture.Id))).Code);
        Assert.Empty(fixture.Store.Records);
    }

    [Fact]
    public async Task MissingInstallationDirectoryCannotObtainAPlanEvenIfAnAdapterWouldClaimIdle()
    {
        var fixture = new Fixture();
        fixture.Observation = fixture.Observation with { InstalledRoot = null };
        var review = await fixture.Reviewer.InspectAsync(fixture.Id);
        Assert.Equal(ActivityState.Unknown, review.Activity.State);
        Assert.Contains("application_activity_unknown", review.BlockingReasons);
        Assert.False(review.CanPreparePlan);
    }

    [Fact]
    public async Task PlanRoundTripsWithExactIdentityConsentAndFifteenMinuteLifetime()
    {
        var fixture = new Fixture();
        var plan = await fixture.CreateAsync();
        var saved = await fixture.Planner.ShowAsync(plan.Id);
        Assert.Equal(plan.Digest, saved.Digest);
        Assert.Equal(TimeSpan.FromMinutes(15), saved.ExpiresAt - saved.CreatedAt);
        Assert.Equal(Sid, saved.OwnerSid);
        Assert.True(saved.AllowInstallerDataChanges);
        Assert.False(saved.ExecutionAvailable);
        Assert.Equal(Package, saved.Review.Installation.Identity!.PackageCode);
        Assert.Single(fixture.Store.Records);
        Assert.Equal(2, fixture.Inspections);
    }

    [Theory]
    [InlineData("owner")]
    [InlineData("consent")]
    [InlineData("identity")]
    [InlineData("digest")]
    [InlineData("unknown_field")]
    [InlineData("missing_issues")]
    [InlineData("default_application_issues")]
    [InlineData("default_warnings")]
    [InlineData("invalid_registered_path")]
    [InlineData("invalid_root_identity")]
    [InlineData("duplicate_property")]
    [InlineData("missing_activity")]
    [InlineData("active_activity")]
    public async Task TamperedSavedPlansNeverBecomeValid(string field)
    {
        var fixture = new Fixture();
        var plan = await fixture.CreateAsync();
        var json = JsonNode.Parse(fixture.Store.Records[plan.Id])!;
        switch (field)
        {
            case "owner": json["owner_sid"] = "S-1-5-21-9999"; break;
            case "consent": json["allow_installer_data_changes"] = false; break;
            case "identity": json["review"]!["installation"]!["identity"]!["system_id"] = Package; break;
            case "digest": json["digest"] = "sha256:" + new string('0', 64); break;
            case "unknown_field": json["approved"] = true; break;
            case "default_application_issues": json["review"]!["application"]!["issues"] = null; break;
            case "default_warnings": json["review"]!["warnings"] = null; break;
            case "invalid_registered_path": json["review"]!["application"]!["registered_install_location"] = "C:/../outside"; break;
            case "invalid_root_identity":
                json["review"]!["installation"]!["installed_root"] = JsonSerializer.SerializeToNode(new FileEntry(WindowsPath.Parse("C:/Example"),
                    new(1, new string('1', 32), Sid), EntryKind.Directory, 0, 0, Now, Now), ContractJson.Options);
                json["review"]!["installation"]!["installed_root"]!["identity"]!["file_id"] = "invalid";
                break;
            case "duplicate_property": break;
            case "missing_activity": json["review"]!.AsObject().Remove("activity"); break;
            case "active_activity": json["review"]!["activity"]!["state"] = "active"; break;
            default: json["review"]!["installation"]!.AsObject().Remove("issues"); break;
        }
        var text = json.ToJsonString();
        if (field == "duplicate_property") text = text.Insert(1, "\"allow_installer_data_changes\":true,");
        fixture.Store.Records[plan.Id] = Encoding.UTF8.GetBytes(text);
        Assert.Equal("corrupt_record", (await Assert.ThrowsAsync<ShouException>(() => fixture.Planner.ShowAsync(plan.Id))).Code);
    }

    [Fact]
    public async Task ComputedExecutionFlagsInLocalJsonCannotGrantExecution()
    {
        var fixture = new Fixture();
        var plan = await fixture.CreateAsync();
        var json = JsonNode.Parse(fixture.Store.Records[plan.Id])!;
        json["execution_available"] = true;
        json["review"]!["execution_available"] = true;
        fixture.Store.Records[plan.Id] = Encoding.UTF8.GetBytes(json.ToJsonString());
        var shown = await fixture.Planner.ShowAsync(plan.Id);
        Assert.False(shown.ExecutionAvailable);
        Assert.False(shown.Review.ExecutionAvailable);
    }

    [Fact]
    public async Task DifferentCurrentUserCannotSaveAPlanForAnotherUserInstallation()
    {
        var fixture = new Fixture();
        fixture.Observation = fixture.Observation with { Identity = fixture.Observation.Identity! with { UserSid = "S-1-5-21-9999" } };
        await Assert.ThrowsAsync<ShouException>(() => fixture.CreateAsync());
        Assert.Empty(fixture.Store.Records);
    }

    [Fact]
    public async Task FailedPublicationAndPreCancellationPreserveTheStore()
    {
        var fixture = new Fixture();
        fixture.Store.FailWrite = true;
        await Assert.ThrowsAsync<ShouException>(() => fixture.CreateAsync());
        Assert.Empty(fixture.Store.Records);
        fixture.Store.FailWrite = false;
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Reviewer.InspectAsync(fixture.Id, cancelled.Token));
        Assert.Empty(fixture.Store.Records);
    }

    [Fact]
    public async Task PartialDiscoveryWarnsWithoutConfusingRegistrationCoverageWithInstallerIdentity()
    {
        var fixture = new Fixture { Partial = true };
        var review = await fixture.Reviewer.InspectAsync(fixture.Id);
        Assert.True(review.CanPreparePlan);
        Assert.Contains("application_discovery_incomplete", review.Warnings);
    }
}
