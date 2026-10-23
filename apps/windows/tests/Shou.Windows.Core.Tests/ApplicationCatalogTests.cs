using System.Collections.Immutable;
using System.Text.Json;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class ApplicationCatalogTests
{
    private static ApplicationRegistration App(string key = "fixture", string name = "Example") => new(ApplicationSource.CurrentUserRegistry,
        key, name, "1.0", "Example Publisher", @"C:\Program Files\Example", 1024);
    private static ApplicationInventory Inventory(params ApplicationRegistration[] registrations) => new(registrations.ToImmutableArray(),
        Enum.GetValues<ApplicationSource>().Select(source => new ApplicationSourceCoverage(source, ApplicationSourceState.Complete,
            registrations.Count(item => item.Source == source), [])).ToImmutableArray());
    private sealed class Reader(ApplicationInventory result) : IApplicationInventory
    {
        public int Calls { get; private set; }
        public Task<ApplicationInventory> ReadAsync(ApplicationDiscoveryBudget budget, CancellationToken cancellationToken)
        { Calls++; return Task.FromResult(result); }
    }
    private static Task<ApplicationCatalogSnapshot> Read(params ApplicationRegistration[] registrations) => new ApplicationCatalog(new Reader(Inventory(registrations))).ReadAsync();

    [Fact]
    public async Task RegistrationFactsRemainExplicitAndNeverBecomeExecutionAuthorization()
    {
        var snapshot = await Read(App());
        Assert.Equal(ScanState.Complete, snapshot.State);
        var application = Assert.Single(snapshot.Applications);
        Assert.Equal(1024, application.RegisteredEstimatedBytes);
        Assert.Equal(@"C:\Program Files\Example", application.RegisteredInstallLocation!.Value);
        Assert.Contains("registration_is_not_file_ownership", snapshot.Limitations);
        Assert.Contains("uninstall_unavailable", snapshot.Limitations);
        var json = JsonSerializer.Serialize(application, ContractJson.Options);
        Assert.DoesNotContain("uninstall_string", json);
        Assert.DoesNotContain("measured_bytes", json);
    }

    [Fact]
    public async Task StableIdsPreserveDifferentRegistrationsWithTheSameDisplayName()
    {
        var first = await Read(App("one"), App("two"), App("one") with { Source = ApplicationSource.MachineRegistry64 });
        var second = await Read(App("two"), App("one"), App("one") with { Source = ApplicationSource.MachineRegistry64 });
        Assert.Equal(3, first.Applications.Select(item => item.Id).Distinct().Count());
        Assert.Equal(first.Applications.Select(item => item.Id).Order(), second.Applications.Select(item => item.Id).Order());
        Assert.NotEqual(first.Id, second.Id);
    }

    [Fact]
    public async Task HiddenComponentsAndUpdatesAreNotPresentedAsIndependentApplications()
    {
        var snapshot = await Read(App(), App("hidden") with { Hidden = true }, App("update") with { IsUpdate = true });
        Assert.Single(snapshot.Applications);
        Assert.Equal(3, snapshot.Sources.Sum(item => item.InspectedEntries));
    }

    [Theory]
    [InlineData("bad\u001b[31m")]
    [InlineData("bad\u202eevil")]
    [InlineData("   ")]
    public async Task UntrustedRegistrationTextIsRejectedWithPartialCoverage(string name)
    {
        var snapshot = await Read(App(name: name));
        Assert.Empty(snapshot.Applications);
        Assert.Equal(ScanState.Partial, snapshot.State);
        Assert.Contains("invalid_registration_metadata", snapshot.Sources[0].Issues);
    }

    [Fact]
    public Task UnpairedSurrogatesAreRejectedBeforeSerialization() => UntrustedRegistrationTextIsRejectedWithPartialCoverage("bad" + (char)0xd800);

    [Fact]
    public async Task UnicodeNamesAndMissingMetadataAreRetainedWithoutInventedSize()
    {
        var snapshot = await Read(new ApplicationRegistration(ApplicationSource.CurrentUserMsix, "package_full_identity", "示例 🧹", IsSystemPackage: true));
        var application = Assert.Single(snapshot.Applications);
        Assert.Equal("示例 🧹", application.Name);
        Assert.True(application.IsSystemPackage);
        Assert.Null(application.RegisteredEstimatedBytes);
        Assert.Null(application.RegisteredInstallLocation);
    }

    [Theory]
    [InlineData("%LOCALAPPDATA%/Example")]
    [InlineData("C:/Example/../Other")]
    [InlineData("//server/share")]
    [InlineData("C:relative")]
    public async Task RegisteredPathsAreNotExpandedOrUsedAsFileEvidence(string path)
    {
        var snapshot = await Read(App() with { InstallLocation = path });
        var application = Assert.Single(snapshot.Applications);
        Assert.Null(application.RegisteredInstallLocation);
        Assert.Contains("invalid_registered_location", application.Issues);
    }

    [Fact]
    public async Task DuplicateExactRegistrationProducesAnExplicitCoverageGap()
    {
        var snapshot = await Read(App(), App());
        Assert.Single(snapshot.Applications);
        Assert.Equal(ScanState.Partial, snapshot.State);
        Assert.Contains("duplicate_registration", snapshot.Sources[0].Issues);
    }

    [Fact]
    public async Task InaccessibleSourceDoesNotEraseOtherApplicationsOrPretendToBeComplete()
    {
        var raw = Inventory(App());
        raw = raw with { Sources = raw.Sources.SetItem(1, raw.Sources[1] with { State = ApplicationSourceState.Unavailable, Issues = ["permission_denied"] }) };
        var snapshot = await new ApplicationCatalog(new Reader(raw)).ReadAsync();
        Assert.Single(snapshot.Applications);
        Assert.Equal(ScanState.Partial, snapshot.State);
        Assert.Equal(ApplicationSourceState.Unavailable, snapshot.Sources[1].State);
    }

    [Fact]
    public async Task AbandonedNativeReadReportsUnknownCountsRatherThanInventingZero()
    {
        var raw = Inventory() with { Sources = Enum.GetValues<ApplicationSource>().Select(source =>
            new ApplicationSourceCoverage(source, ApplicationSourceState.Unavailable, null, ["time_limit"])).ToImmutableArray() };
        var snapshot = await new ApplicationCatalog(new Reader(raw)).ReadAsync();
        Assert.Equal(ScanState.Partial, snapshot.State);
        Assert.All(snapshot.Sources, source => Assert.Null(source.InspectedEntries));
        var invalid = raw with { Sources = raw.Sources.SetItem(0, raw.Sources[0] with { State = ApplicationSourceState.Complete }) };
        await Assert.ThrowsAsync<ShouException>(() => new ApplicationCatalog(new Reader(invalid)).ReadAsync());
    }

    [Fact]
    public async Task SearchAndPaginationUseOneImmutableSnapshotWithDeterministicSorting()
    {
        var snapshot = await Read(App("one", "Zulu") with { RegisteredEstimatedBytes = null }, App("two", "Alpha") with { RegisteredEstimatedBytes = 0 }, App("three", "Beta"));
        var first = ApplicationCatalog.Page(snapshot, new(Sort: ApplicationSort.RegisteredSize, Limit: 2));
        var next = ApplicationCatalog.Page(snapshot, new(Sort: ApplicationSort.RegisteredSize, Offset: 2, Limit: 2));
        Assert.Equal(new[] { "Beta", "Alpha" }, first.Items.Select(item => item.Name));
        Assert.True(first.HasNext);
        Assert.Equal("Zulu", Assert.Single(next.Items).Name);
        Assert.False(next.HasNext);
        Assert.Equal(first.SnapshotId, next.SnapshotId);
        Assert.Equal(3, ApplicationCatalog.Page(snapshot, new("publisher")).Total);
        Assert.Equal(1, ApplicationCatalog.Page(snapshot, new("tHrEe")).Total);
        Assert.Empty(ApplicationCatalog.Page(snapshot, new("unmatched")).Items);
    }

    [Fact]
    public async Task MissingSourceCoverageAndBudgetOverflowAreRejected()
    {
        var missing = Inventory(App()) with { Sources = [] };
        Assert.Equal("application_inventory_invalid", (await Assert.ThrowsAsync<ShouException>(() => new ApplicationCatalog(new Reader(missing)).ReadAsync())).Code);
        var overflow = Inventory(App(), App("two"));
        await Assert.ThrowsAsync<ShouException>(() => new ApplicationCatalog(new Reader(overflow)).ReadAsync(new(MaxEntries: 1)));
    }

    [Fact]
    public async Task InvalidBudgetAndPreCancellationDoNotInvokeThePlatform()
    {
        var reader = new Reader(Inventory());
        var catalog = new ApplicationCatalog(reader);
        await Assert.ThrowsAsync<ShouException>(() => catalog.ReadAsync(new(MaxEntries: 0)));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => catalog.ReadAsync(cancellationToken: cancelled.Token));
        Assert.Equal(0, reader.Calls);
    }

    [Theory]
    [InlineData(-1, 100)]
    [InlineData(20001, 100)]
    [InlineData(0, 0)]
    [InlineData(0, 501)]
    public void InvalidPagesAreRejected(int offset, int limit) => Assert.Throws<ShouException>(() => new ApplicationQuery(Offset: offset, Limit: limit).Validate());
}
