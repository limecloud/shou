using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class ProvisionedScanLocationTests
{
    private const string Actor = "S-1-5-21-1000";
    private const string Admin = "S-1-5-32-544";
    private static readonly WindowsPath Home = WindowsPath.Parse("C:/Users/fixture");
    private static readonly RuleSchemaValidator Validator = new(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Contracts/rule.schema.json")));

    private sealed class Files : IWindowsFileSystem, IProvisionedScanAccess
    {
        internal readonly MemoryFileSystem Inner = new();
        internal readonly List<(WindowsPath Root, WindowsPath Anchor)> Verifications = [];
        internal bool Trusted = true;
        public ValueTask<FileEntry> InspectAsync(WindowsPath path, CancellationToken token) => Inner.InspectAsync(path, token);
        public IAsyncEnumerable<DirectoryReadItem> ReadDirectoryAsync(WindowsPath path, CancellationToken token) => Inner.ReadDirectoryAsync(path, token);
        public ValueTask VerifyReadOnlyRootAsync(FileEntry root, WindowsPath anchor, string owner, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            Assert.Equal(Actor, owner);
            Verifications.Add((root.Path, anchor));
            if (!Trusted) throw new ShouException("scan_location_permissions", "Generated untrusted ACL.");
            return ValueTask.CompletedTask;
        }
    }

    private sealed class Fixture
    {
        internal readonly Files Files = new();
        internal readonly MemoryRecordStore Store = new();
        internal readonly BuiltinRuleCatalog Catalog = new(Validator, new(Home, Home.Append("AppData/Local"), Home.Append("AppData/Roaming")),
            Resource("builtin-rules"), Resource("known-locations"), Resource("project-locations"));
        internal ConfigurationService Configuration => new(Store, Validator, Files, Actor, catalog: Catalog);
        internal ScanLocationService Locations => new(Configuration, Catalog, Files, Actor);
        internal CleanupProtectionContext Protection => new(Actor, Home, Home.Append("AppData/Local/Shou/Data"), []);
        internal CleanupScanService Scans => new(Store, Validator, new CleanupScanner(Files), Protection, catalog: Catalog);
        internal FileEntry Root(string id, string owner = Admin)
        {
            var path = Catalog.Locations.Single(location => location.Id == id).Path;
            return Files.Inner.Add(path.Value, EntryKind.Directory, identity: new(1, (Files.Inner.Entries.Count + 100).ToString("x32"), owner));
        }
        private static byte[] Resource(string name) => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Catalog", name + ".json"));
    }

    [Theory]
    [InlineData(Admin)]
    [InlineData("S-1-5-18")]
    public async Task ScreenshotLocationsAreDiscoveredRegisteredAndScannedWithoutChangingTheirOwners(string owner)
    {
        var fixture = new Fixture();
        var roots = new[] { "windows-chrome", "windows-edge", "windows-nuget" }.Select(id => fixture.Root(id, owner)).ToArray();
        foreach (var root in roots)
        {
            if (root.Path.Name == "NuGet") fixture.Files.Inner.Add(root.Path.Append("v3-cache").Value, EntryKind.Directory);
            else
            {
                fixture.Files.Inner.Add(root.Path.Append("Default").Value, EntryKind.Directory);
                fixture.Files.Inner.Add(root.Path.Append("Default/Cache").Value, EntryKind.Directory);
            }
        }
        var discovered = await fixture.Locations.DiscoverAsync();
        Assert.Equal(3, discovered.Locations.Count(location => location.State == "available"));
        Assert.Empty(fixture.Store.Records);
        var batch = await fixture.Locations.ScanAsync(fixture.Scans, false, new());
        Assert.Equal("complete", batch.State); Assert.Empty(batch.Issues); Assert.Equal(3, batch.Scans.Length);
        foreach (var scan in batch.Scans)
        {
            var candidate = Assert.Single(scan.Candidates);
            Assert.True(candidate.Complete); Assert.Equal("blocked", candidate.State);
            Assert.Contains("scan_root_read_only", candidate.BlockedReasons);
            var saved = await fixture.Scans.ResultsAsync(scan.Id);
            Assert.Contains("scan_root_read_only", Assert.Single(saved.Candidates).BlockedReasons);
        }
        Assert.All(roots, root => Assert.Equal(root, fixture.Files.Inner.Entries[root.Path.Value]));
        Assert.All(fixture.Files.Verifications, call => Assert.Equal(Home.Append("AppData/Local"), call.Anchor));
        Assert.All((await fixture.Configuration.ReadAsync()).Workspaces, root => Assert.Equal(owner, root.Identity.OwnerSid));
    }

    [Fact]
    public async Task ReadOnlyRootCannotBecomeACleanupPlanEvenWhenTheTargetBelongsToTheActor()
    {
        var fixture = new Fixture(); var root = fixture.Root("windows-nuget");
        fixture.Files.Inner.Add(root.Path.Append("v3-cache").Value, EntryKind.Directory);
        var scan = Assert.Single((await fixture.Locations.ScanAsync(fixture.Scans, false, new())).Scans);
        var service = new CleanupService(fixture.Store, Validator, new CleanupScanner(fixture.Files), fixture.Protection,
            new NeverActivity(), new NeverMutation(), catalog: fixture.Catalog);
        await Assert.ThrowsAsync<ShouException>(() => service.CreatePlanAsync(scan.Id, [Assert.Single(scan.Candidates).Id]));
        Assert.DoesNotContain(fixture.Store.Records.Keys, key => key.StartsWith("plan_", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("S-1-5-21-2000", true, "foreign_owner")]
    [InlineData(Admin, false, "scan_location_permissions")]
    public async Task ForeignOwnersAndUntrustedPermissionsAreReportedSeparately(string owner, bool trusted, string code)
    {
        var fixture = new Fixture(); var root = fixture.Root("windows-chrome", owner); fixture.Files.Trusted = trusted;
        var prepared = await fixture.Locations.PrepareAsync();
        Assert.Empty(prepared.Workspaces); Assert.Contains(new ScanIssue(root.Path, code), prepared.Issues);
        Assert.Empty((await fixture.Configuration.ReadAsync()).Workspaces);
    }

    [Fact]
    public async Task ProjectHintsAndManualRegistrationsDoNotInheritTheBuiltinReadOnlyException()
    {
        var fixture = new Fixture();
        fixture.Files.Inner.Add(Home.Append("Projects").Value, EntryKind.Directory, identity: new(1, new string('e', 32), Admin));
        var root = fixture.Root("windows-nuget");
        var result = await fixture.Locations.DiscoverAsync(true);
        Assert.Contains(result.Locations, location => location.Path == Home.Append("Projects") && location.Issue == "foreign_owner");
        Assert.DoesNotContain(fixture.Files.Verifications, call => call.Root == Home.Append("Projects"));
        await Assert.ThrowsAsync<ShouException>(() => fixture.Configuration.AddWorkspaceAsync(root.Path, "manual"));
    }

    [Fact]
    public async Task RegistrationAndRescanRecheckPermissionsInsteadOfTrustingTheSavedObservation()
    {
        var fixture = new Fixture(); var root = fixture.Root("windows-nuget");
        var discovery = await fixture.Locations.DiscoverAsync();
        var location = discovery.Locations.Single(location => location.State == "available");
        var proposed = new Workspace(RecordKey.New("ws"), "shou-location-" + location.Id, root.Path, root.Identity, false, [], DateTimeOffset.UnixEpoch);
        fixture.Files.Trusted = false;
        var error = await Assert.ThrowsAsync<ShouException>(() => fixture.Configuration.RegisterDiscoveredAsync([proposed], discovery.ConfigurationRevision));
        Assert.Equal("scan_location_permissions", error.Code); Assert.Empty((await fixture.Configuration.ReadAsync()).Workspaces);
        fixture.Files.Trusted = true;
        var workspace = Assert.Single((await fixture.Locations.PrepareAsync()).Workspaces);
        fixture.Files.Trusted = false;
        Assert.False(await fixture.Configuration.IsAccessibleAsync(workspace));
        var scan = await fixture.Locations.ScanRegisteredAsync(fixture.Scans, [workspace.Id], new());
        Assert.Empty(scan.Scans); Assert.Equal("partial", scan.State);
    }

    [Fact]
    public async Task ReparseRootsAreNeverGivenProvisionedAccess()
    {
        var fixture = new Fixture(); var root = fixture.Root("windows-chrome");
        fixture.Files.Inner.Entries[root.Path.Value] = root with { Kind = EntryKind.ReparsePoint };
        var result = await fixture.Locations.PrepareAsync();
        Assert.Empty(result.Workspaces); Assert.Empty(fixture.Files.Verifications);
        Assert.Contains(new ScanIssue(root.Path, "unsupported_location"), result.Issues);
    }

    [Fact]
    public async Task AdaptersWithoutProvisionedAccessFailClosedEvenAtABuiltinPath()
    {
        var fixture = new Fixture(); var root = fixture.Root("windows-nuget");
        var configuration = new ConfigurationService(fixture.Store, Validator, fixture.Files.Inner, Actor, catalog: fixture.Catalog);
        var locations = new ScanLocationService(configuration, fixture.Catalog, fixture.Files.Inner, Actor);
        var result = await locations.PrepareAsync();
        Assert.Empty(result.Workspaces); Assert.Contains(new ScanIssue(root.Path, "foreign_owner"), result.Issues);
    }

    [Fact]
    public async Task ARejectedReadOnlyRootDoesNotConsumeTheBudgetForIndependentCurrentUserRoots()
    {
        var fixture = new Fixture(); fixture.Root("windows-chrome");
        var ordinary = fixture.Root("windows-nuget", Actor);
        fixture.Files.Inner.Add(ordinary.Path.Append("v3-cache").Value, EntryKind.Directory);
        var prepared = await fixture.Locations.PrepareAsync(); Assert.Equal(2, prepared.Workspaces.Length);
        fixture.Files.Trusted = false;
        var batch = await fixture.Locations.ScanRegisteredAsync(fixture.Scans, prepared.Workspaces.Select(root => root.Id).ToImmutableArray(), new());
        Assert.Equal("partial", batch.State);
        Assert.Equal(ordinary.Path, Assert.Single(batch.Scans).Workspace.Path);
        Assert.Equal("review", Assert.Single(batch.Scans[0].Candidates).State);
    }

    private sealed class NeverActivity : ICleanupActivity
    {
        public Task<ActivityObservation> InspectAsync(Workspace workspace, CleanupPlanItem item, CancellationToken token) =>
            throw new InvalidOperationException("A read-only root must never reach mutation preparation.");
    }
    private sealed class NeverMutation : ICleanupMutation
    {
        public bool Supports(CleanupAction action) => true;
        public Task<CleanupMutationResult> ApplyAsync(Workspace workspace, CleanupPlanItem item, CleanupAction action, CancellationToken token) =>
            throw new InvalidOperationException("These tests never mutate targets.");
    }
}
