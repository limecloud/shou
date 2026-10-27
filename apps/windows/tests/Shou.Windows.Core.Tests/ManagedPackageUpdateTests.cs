using System.Collections.Immutable;

namespace Shou.Windows.Core.Tests;

public sealed class ManagedPackageUpdateTests
{
    private static ManagedPackageUpdate Package(string id = "Example.App") => new(id, id, "1.0", "2.0", "installation-identity",
        ManagedPackageScope.User, ManagedPackageUpdateService.OfficialCatalogId, "", true, null);

    private sealed class Platform(params ManagedPackageUpdate[] initial) : IManagedPackageUpdates
    {
        public ImmutableArray<ManagedPackageUpdate> Packages = [.. initial];
        public bool Complete = true;
        public int Reads;
        public List<string> Dispatches { get; } = [];
        public Action<int>? BeforeRead;
        public Func<ManagedPackageUpdate, CancellationToken, ManagedPackageMutationResult>? Mutation;
        public Task<ManagedPackageSnapshot> ReadAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested(); BeforeRead?.Invoke(++Reads);
            return Task.FromResult(new ManagedPackageSnapshot(DateTimeOffset.UtcNow, Packages, Complete, Complete ? null : "incomplete"));
        }
        public Task<ManagedPackageMutationResult> UpgradeAsync(ManagedPackageUpdate expected, DateTimeOffset authorizationExpiresAt, CancellationToken cancellationToken)
        {
            Dispatches.Add(expected.Id);
            if (Mutation is not null) return Task.FromResult(Mutation(expected, cancellationToken));
            Packages = Packages.Select(p => p.Id == expected.Id ? p with { InstalledVersion = expected.AvailableVersion!, CanUpgrade = false, Reason = "package_no_update" } : p).ToImmutableArray();
            return Task.FromResult(new ManagedPackageMutationResult(true, true, false, null));
        }
    }

    [Fact]
    public async Task ConfirmsOnlyFrozenSelectionAndRejectsReplay()
    {
        var selected = Package(); var other = Package("Example.Other");
        var platform = new Platform(selected, other); var service = new ManagedPackageUpdateService(platform);
        var plan = await service.PrepareAsync([selected]);
        var result = Assert.Single(await service.ExecuteAsync(plan, plan.Id));
        Assert.Equal(ManagedPackageUpdateOutcome.Verified, result.Outcome);
        Assert.Equal("2.0", result.ObservedVersion);
        Assert.Equal([selected.Id], platform.Dispatches);
        Assert.Equal("1.0", platform.Packages.Single(p => p.Id == other.Id).InstalledVersion);
        Assert.Equal("package_update_plan_stale", (await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan, plan.Id))).Code);
    }

    [Theory]
    [InlineData("identity")]
    [InlineData("version")]
    [InlineData("target")]
    [InlineData("scope")]
    [InlineData("agreement")]
    [InlineData("partial")]
    public async Task PreflightRejectsChangedIdentityVersionTargetScopeAndAgreements(string change)
    {
        var selected = Package(); var platform = new Platform(selected); var service = new ManagedPackageUpdateService(platform);
        var plan = await service.PrepareAsync([selected]);
        platform.Packages = [change switch
        {
            "identity" => selected with { InstallationIdentity = "different" },
            "version" => selected with { InstalledVersion = "1.1" },
            "target" => selected with { AvailableVersion = "3.0" },
            "scope" => selected with { Scope = ManagedPackageScope.System },
            "agreement" => selected with { CanUpgrade = false, Reason = "package_agreement_required" },
            _ => selected
        }];
        platform.Complete = change != "partial";
        await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan, plan.Id));
        Assert.Empty(platform.Dispatches);
        await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan, plan.Id));
    }

    [Fact]
    public async Task InvalidSourceDuplicateAndUnsupportedSelectionNeverReachInstaller()
    {
        var selected = Package(); var platform = new Platform(selected); var service = new ManagedPackageUpdateService(platform);
        await Assert.ThrowsAsync<ShouException>(() => service.PrepareAsync([selected, selected]));
        await Assert.ThrowsAsync<ShouException>(() => service.PrepareAsync([selected with { CanUpgrade = false }]));
        platform.Packages = [selected with { CatalogId = "custom-winget" }];
        await Assert.ThrowsAsync<ShouException>(() => service.PrepareAsync([selected]));
        Assert.Empty(platform.Dispatches);
    }

    [Fact]
    public async Task SuccessNeedsFreshInstalledVersionAndUnknownStopsRemainingUpdates()
    {
        var selected = Package(); var platform = new Platform(selected, Package("Example.Other"))
        { Mutation = (_, _) => new(true, true, false, null) };
        var service = new ManagedPackageUpdateService(platform); var plan = await service.PrepareAsync(platform.Packages);
        var results = await service.ExecuteAsync(plan, plan.Id);
        Assert.Equal(ManagedPackageUpdateOutcome.Unknown, results[0].Outcome);
        Assert.Equal(ManagedPackageUpdateOutcome.NotStarted, results[1].Outcome);
        Assert.Single(platform.Dispatches);
    }

    [Fact]
    public async Task CancellationAfterDispatchStillVerifiesCurrentResultAndSkipsNextPackage()
    {
        using var stop = new CancellationTokenSource();
        var selected = Package(); var platform = new Platform(selected, Package("Example.Other"));
        platform.Mutation = (package, _) =>
        {
            platform.Packages = platform.Packages.Select(p => p.Id == package.Id ? p with { InstalledVersion = "2.0", CanUpgrade = false, Reason = "package_no_update" } : p).ToImmutableArray();
            stop.Cancel(); return new(true, true, true, null);
        };
        var service = new ManagedPackageUpdateService(platform); var plan = await service.PrepareAsync(platform.Packages);
        var results = await service.ExecuteAsync(plan, plan.Id, stop.Token);
        Assert.Equal(ManagedPackageUpdateOutcome.Verified, results[0].Outcome);
        Assert.True(results[0].RestartRequired);
        Assert.Equal(ManagedPackageUpdateOutcome.NotStarted, results[1].Outcome);
        Assert.Single(platform.Dispatches);
    }

    [Fact]
    public async Task OneFailedInstallerDoesNotMisreportOtherSelectedResults()
    {
        var first = Package(); var second = Package("Example.Other"); var platform = new Platform(first, second);
        platform.Mutation = (package, _) =>
        {
            if (package.Id == first.Id) return new(false, true, false, "installer_failed");
            platform.Packages = [first, second with { InstalledVersion = "2.0", CanUpgrade = false, Reason = "package_no_update" }];
            return new(true, true, false, null);
        };
        var service = new ManagedPackageUpdateService(platform); var plan = await service.PrepareAsync(platform.Packages);
        var results = await service.ExecuteAsync(plan, plan.Id);
        Assert.Equal(ManagedPackageUpdateOutcome.Failed, results[0].Outcome);
        Assert.Equal(ManagedPackageUpdateOutcome.Verified, results[1].Outcome);
    }

    [Fact]
    public async Task EachRemainingPackageIsRecheckedAfterEarlierInstallersFinish()
    {
        var first = Package(); var second = Package("Example.Other"); var platform = new Platform(first, second);
        platform.BeforeRead = read =>
        {
            if (read == 5) platform.Packages = platform.Packages.Select(p => p.Id == second.Id ? p with { InstallationIdentity = "replaced" } : p).ToImmutableArray();
        };
        var service = new ManagedPackageUpdateService(platform); var plan = await service.PrepareAsync(platform.Packages);
        var results = await service.ExecuteAsync(plan, plan.Id);
        Assert.Equal(ManagedPackageUpdateOutcome.Verified, results[0].Outcome);
        Assert.Equal(ManagedPackageUpdateOutcome.NotStarted, results[1].Outcome);
        Assert.Equal([first.Id], platform.Dispatches);
    }

    [Fact]
    public async Task ExpiredPlanAndWrongConfirmationNeverDispatch()
    {
        var selected = Package(); var platform = new Platform(selected); var clock = new Clock();
        var service = new ManagedPackageUpdateService(platform, clock); var plan = await service.PrepareAsync([selected]);
        await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan, "wrong-plan"));
        clock.Now += TimeSpan.FromMinutes(3);
        await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan, plan.Id));
        Assert.Empty(platform.Dispatches);
    }

    private sealed class Clock : TimeProvider
    {
        internal DateTimeOffset Now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => Now;
    }
}
