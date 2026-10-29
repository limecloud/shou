using System.Collections.Immutable;
using System.Text;
using System.Text.Json.Nodes;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class BuiltinDiscoveryTests
{
    private const string Owner = "S-1-5-21-1000";
    private static readonly WindowsPath Home = WindowsPath.Parse("C:/Users/开发者");
    private static readonly RuleSchemaValidator Validator = new(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Contracts/rule.schema.json")));
    private static byte[] Resource(string name) => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Catalog", name + ".json"));
    private static BuiltinRuleCatalog Catalog(byte[]? templates = null, byte[]? locations = null, byte[]? projects = null, WindowsUserDirectories? directories = null) => new(Validator,
        directories ?? new(Home, Home.Append("AppData/Local"), Home.Append("AppData/Roaming")), templates ?? Resource("builtin-rules"), locations ?? Resource("known-locations"), projects ?? Resource("project-locations"));
    private static Workspace Workspace(WindowsPath path, string reference = "projects") => new(RecordKey.New("ws"), reference, path, new(1, new string('1', 32), Owner), false, [], DateTimeOffset.UnixEpoch);

    private sealed class Fixture
    {
        public MemoryFileSystem Files = new();
        public MemoryRecordStore Store = new();
        public BuiltinRuleCatalog Catalog = BuiltinDiscoveryTests.Catalog();
        public ConfigurationService Configuration => new(Store, Validator, Files, Owner, catalog: Catalog);
        public ScanLocationService Locations => new(Configuration, Catalog, Files, Owner);
        public CleanupProtectionContext Protection = new(Owner, Home, Home.Append("AppData/Local/Shou/Data"), [WindowsPath.Parse("C:/Windows")]);
        public CleanupScanService Scans => new(Store, Validator, new StorageScanner(Files), Protection, catalog: Catalog);
        public CleanupService Cleanup => new(Store, Validator, new StorageScanner(Files), Protection, new Idle(), new Mutation(), catalog: Catalog);
        public void Project(string relative)
        {
            var path = Home.Append(relative);
            Files.Add(path.Value, EntryKind.Directory);
            Files.Add(path.Append("Cargo.toml").Value);
            Files.Add(path.Append("target").Value, EntryKind.Directory);
            Files.Add(path.Append("target/cache.bin").Value);
        }
    }
    private sealed class Idle : ICleanupActivity
    { public Task<ActivityObservation> InspectAsync(Workspace workspace, CleanupPlanItem item, CancellationToken token) => Task.FromResult(new ActivityObservation(ActivityState.Idle)); }
    private sealed class Mutation : ICleanupMutation
    {
        public bool Supports(CleanupAction action) => action == CleanupAction.Permanent;
        public Task<CleanupMutationResult> ApplyAsync(Workspace workspace, CleanupPlanItem item, CleanupAction action, CancellationToken token) => throw new InvalidOperationException("This test never mutates targets.");
    }
    private sealed class Confirmation : ICleanupConfirmation
    { public Task<bool> RequestAsync(CleanupReview review, CancellationToken token) => Task.FromResult(true); }

    [Fact]
    public void BundledDefinitionsValidateAndRespectRedirectedAppData()
    {
        var catalog = Catalog(directories: new(Home, WindowsPath.Parse("D:/Profile/Local"), WindowsPath.Parse("D:/Profile/Roaming")));
        Assert.Equal(39, catalog.Templates.Length); Assert.Equal(23, catalog.Locations.Length); Assert.Equal(30, catalog.ProjectPaths.Length);
        Assert.Equal(WindowsPath.Parse("D:/Profile/Local/Google/Chrome/User Data"), catalog.Locations.Single(value => value.Id == "windows-chrome").Path);
        Assert.Equal(WindowsPath.Parse("D:/Profile/Roaming/Code"), catalog.Locations.Single(value => value.Id == "windows-vscode").Path);
        Assert.All(catalog.Templates, template => Assert.True(catalog.Rule(template, "fixture").AppliesToWindows));
    }

    [Fact]
    public void FixedAndProjectRulesHaveSeparateExactScopes()
    {
        var catalog = Catalog();
        var chrome = catalog.Locations.Single(value => value.Id == "windows-chrome");
        Assert.Equal("shou.builtin.windows-chrome", Assert.Single(catalog.RulesFor(Workspace(chrome.Path))).Id);
        Assert.Empty(catalog.RulesFor(Workspace(chrome.Path.Parent!)));
        Assert.Empty(catalog.RulesFor(Workspace(chrome.Path.Append("Default"))));
        Assert.Empty(catalog.RulesFor(Workspace(WindowsPath.Parse(chrome.Path.Value.Replace("Google", "GOOGLE", StringComparison.Ordinal)))));
        var projects = catalog.RulesFor(Workspace(Home.Append("Projects")));
        Assert.Equal(16, projects.Length);
        Assert.All(projects, rule => Assert.Equal("projects", rule.RootReference));
        Assert.DoesNotContain(projects, rule => rule.Id == "shou.builtin.windows-chrome");
    }

    [Theory]
    [InlineData("../outside")]
    [InlineData("Projects/*")]
    [InlineData("C:/Projects")]
    public void UnsafeProjectHintResourcesAreRejected(string path)
    {
        var error = Assert.Throws<ShouException>(() => Catalog(projects: Encoding.UTF8.GetBytes(new JsonArray(path).ToJsonString())));
        Assert.Equal("resource_unavailable", error.Code);
    }

    [Fact]
    public void DuplicateIdsUnscopedTemplatesAndUnsupportedPlatformsRejectTheCatalog()
    {
        var templates = JsonNode.Parse(Resource("builtin-rules"))!.AsArray();
        templates.Add(templates[0]!.DeepClone());
        Assert.Throws<ShouException>(() => Catalog(templates: Encoding.UTF8.GetBytes(templates.ToJsonString())));
        templates.RemoveAt(templates.Count - 1);
        templates[0]!["location"] = "missing-location";
        Assert.Throws<ShouException>(() => Catalog(templates: Encoding.UTF8.GetBytes(templates.ToJsonString())));
        templates[0]!["location"] = "projects"; templates[0]!["platforms"] = new JsonArray("macos");
        Assert.Throws<ShouException>(() => Catalog(templates: Encoding.UTF8.GetBytes(templates.ToJsonString())));
    }

    [Fact]
    public async Task DiscoveryReadsMetadataWithoutRegisteringMissingOrExistingLocations()
    {
        var fixture = new Fixture(); fixture.Project("Projects");
        var fixedLocation = fixture.Catalog.Locations.Single(value => value.Id == "windows-npm");
        fixture.Files.Add(fixedLocation.Path.Value, EntryKind.Directory);
        var fixedOnly = await fixture.Locations.DiscoverAsync();
        Assert.Single(fixedOnly.Locations.Where(value => value.State == "available"));
        Assert.DoesNotContain(fixedOnly.Locations, value => value.Path == Home.Append("Projects"));
        var all = await fixture.Locations.DiscoverAsync(true);
        Assert.Contains(all.Locations, value => value.Path == Home.Append("Projects") && value.State == "available");
        Assert.All(all.Locations.Where(value => value.State == "missing"), value => Assert.Null(value.Issue));
        Assert.Empty(fixture.Store.Records); Assert.Equal(0, fixture.Store.Writes);
    }

    [Fact]
    public async Task ExplicitNestedScopeWinsAndItsExclusionsAndDisabledRulesArePreserved()
    {
        var fixture = new Fixture(); fixture.Project("Projects/one");
        fixture.Files.Add(Home.Append("Projects").Value, EntryKind.Directory);
        var saved = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Projects/one"), "user-project");
        await fixture.Configuration.SetExclusionAsync(saved.Id, "**/keep", false);
        await fixture.Configuration.SetRuleAsync(saved.Id, "shou.builtin.rust-target", false, "1.1.0");
        var before = (await fixture.Configuration.ReadAsync()).Revision;
        var prepared = await fixture.Locations.PrepareAsync(true);
        Assert.Equal(saved.Id, Assert.Single(prepared.Workspaces).Id);
        Assert.Equal(new[] { "**/keep" }, prepared.Workspaces[0].Exclusions.ToArray());
        var current = await fixture.Configuration.ReadAsync();
        Assert.Equal(before, current.Revision); Assert.False(Assert.Single(current.Bindings).Enabled);
        Assert.DoesNotContain(current.Workspaces, value => value.Path == Home.Append("Projects"));
    }

    [Fact]
    public async Task CaseAliasesAndPhysicalAliasesDoNotDuplicateAutomaticRegistrations()
    {
        var fixture = new Fixture();
        var first = fixture.Files.Add(Home.Append("Code").Value, EntryKind.Directory);
        fixture.Files.Add(Home.Append("code").Value, EntryKind.Directory, identity: first.Identity);
        fixture.Files.Add(Home.Append("repos").Value, EntryKind.Directory, identity: first.Identity);
        var prepared = await fixture.Locations.PrepareAsync(true);
        Assert.Single(prepared.Workspaces); Assert.Single((await fixture.Configuration.ReadAsync()).Workspaces);
    }

    [Fact]
    public async Task ReparseForeignAndReplacedRootsStayUnavailable()
    {
        var fixture = new Fixture();
        fixture.Files.Add(Home.Append("Projects").Value, EntryKind.ReparsePoint);
        fixture.Files.Add(Home.Append("Code").Value, EntryKind.Directory, identity: new(1, new string('2', 32), "S-1-5-21-2000"));
        var root = fixture.Files.Add(Home.Append("dev").Value, EntryKind.Directory);
        var saved = await fixture.Configuration.AddWorkspaceAsync(root.Path, "saved");
        fixture.Files.Entries[root.Path.Value] = root with { Identity = new(1, new string('3', 32), Owner) };
        var result = await fixture.Locations.PrepareAsync(true);
        Assert.Empty(result.Workspaces);
        Assert.Equal(3, result.Issues.Length);
        Assert.Equal(saved.Identity, Assert.Single((await fixture.Configuration.ReadAsync()).Workspaces).Identity);
    }

    [Fact]
    public async Task RegistrationRechecksBothIdentityAndTheDiscoveryConfigurationRevision()
    {
        var fixture = new Fixture(); fixture.Project("Projects");
        var discovery = await fixture.Locations.DiscoverAsync(true);
        var observed = discovery.Locations.Single(value => value.State == "available");
        var proposed = Workspace(observed.Path, "shou-location-" + observed.Id) with { Identity = observed.Identity!, CaseSensitive = observed.CaseSensitive };
        await fixture.Configuration.SetExclusionAsync(null, "**/keep", false);
        var error = await Assert.ThrowsAsync<ShouException>(() => fixture.Configuration.RegisterDiscoveredAsync([proposed], discovery.ConfigurationRevision));
        Assert.Equal("plan_stale", error.Code); Assert.Empty((await fixture.Configuration.ReadAsync()).Workspaces);
        var current = await fixture.Configuration.ReadAsync();
        var previous = fixture.Files.Entries[observed.Path.Value];
        fixture.Files.Entries[observed.Path.Value] = previous with { Identity = new(1, new string('9', 32), Owner) };
        error = await Assert.ThrowsAsync<ShouException>(() => fixture.Configuration.RegisterDiscoveredAsync([proposed], current.Revision));
        Assert.Equal("source_changed", error.Code); Assert.Empty((await fixture.Configuration.ReadAsync()).Workspaces);
    }

    [Fact]
    public async Task ConflictingDiscoveryBatchNeverPublishesOnlyItsFirstRegistration()
    {
        var fixture = new Fixture();
        var first = fixture.Files.Add(Home.Append("Projects").Value, EntryKind.Directory);
        var second = fixture.Files.Add(first.Path.Append("one").Value, EntryKind.Directory);
        var proposed = new[] { first, second }.Select((entry, index) => Workspace(entry.Path, "shou-location-" + index) with { Identity = entry.Identity }).ToImmutableArray();
        await Assert.ThrowsAsync<ShouException>(() => fixture.Configuration.RegisterDiscoveredAsync(proposed, Configuration.Empty.Revision));
        Assert.Empty(fixture.Store.Records); Assert.Equal(0, fixture.Store.Writes);
    }

    [Fact]
    public async Task BundledRulesWorkWithoutPersonalImportsAndStillProtectSourceAndExclusions()
    {
        var fixture = new Fixture(); fixture.Project("Projects");
        var prepared = await fixture.Locations.PrepareAsync(true);
        var workspace = Assert.Single(prepared.Workspaces);
        var scan = await fixture.Scans.ScanAsync(workspace.Id, new());
        var target = scan.Candidates.Single(value => value.RuleId == "shou.builtin.rust-target");
        Assert.Equal("review", target.State); Assert.Empty((await fixture.Configuration.ReadAsync()).Rules);
        fixture.Files.Add(Home.Append("Projects/target/main.rs").Value);
        scan = await fixture.Scans.ScanAsync(workspace.Id, new());
        Assert.Contains("protected_data", scan.Candidates.Single(value => value.RuleId == target.RuleId).BlockedReasons);
        await fixture.Configuration.SetExclusionAsync(workspace.Id, "target", false);
        scan = await fixture.Scans.ScanAsync(workspace.Id, new());
        Assert.Contains("excluded", scan.Candidates.Single(value => value.RuleId == target.RuleId).BlockedReasons);
    }

    [Fact]
    public async Task DisablePreferencesSurviveCatalogUpdatesAndUnknownBindingsCannotIntroduceDefinitions()
    {
        var fixture = new Fixture(); fixture.Project("Projects");
        var workspace = Assert.Single((await fixture.Locations.PrepareAsync(true)).Workspaces);
        await fixture.Configuration.SetRuleAsync(workspace.Id, "shou.builtin.rust-target", false, "1.1.0");
        var updated = JsonNode.Parse(Resource("builtin-rules"))!.AsArray(); updated[0]!["version"] = "1.2.0";
        fixture.Catalog = Catalog(templates: Encoding.UTF8.GetBytes(updated.ToJsonString()));
        var scan = await fixture.Scans.ScanAsync(workspace.Id, new());
        Assert.DoesNotContain(scan.Candidates, value => value.RuleId == "shou.builtin.rust-target");
        await Assert.ThrowsAsync<ShouException>(() => fixture.Configuration.SetRuleAsync(workspace.Id, "shou.builtin.rust-target", true, "1.1.0"));
        var current = await fixture.Configuration.ReadAsync();
        current = current with { Bindings = current.Bindings.Add(new(workspace.Id, "shou.builtin.unknown", "1.0.0", "sha256:" + new string('a', 64), true)) };
        fixture.Store.Records["configuration"] = new ConfigurationCodec(Validator).Encode(current);
        scan = await fixture.Scans.ScanAsync(workspace.Id, new());
        Assert.DoesNotContain(scan.Rules, value => value.Definition.GetProperty("id").GetString() == "shou.builtin.unknown");
        await fixture.Configuration.SetRuleAsync(workspace.Id, "shou.builtin.rust-target", true, "1.2.0");
        Assert.Contains((await fixture.Scans.ScanAsync(workspace.Id, new())).Candidates, value => value.RuleId == "shou.builtin.rust-target");
    }

    [Fact]
    public async Task BuiltinPlansUseCurrentCatalogDigestsEvenWithoutAnExplicitEnableBinding()
    {
        var fixture = new Fixture(); fixture.Project("Projects");
        var workspace = Assert.Single((await fixture.Locations.PrepareAsync(true)).Workspaces);
        var scan = await fixture.Scans.ScanAsync(workspace.Id, new());
        var selected = scan.Candidates.Single(value => value.RuleId == "shou.builtin.rust-target");
        var plan = await fixture.Cleanup.CreatePlanAsync(scan.Id, [selected.Id]);
        Assert.NotNull(await fixture.Cleanup.ConfirmAsync(plan.Id, new Confirmation()));
        var updated = JsonNode.Parse(Resource("builtin-rules"))!.AsArray(); updated[0]!["version"] = "1.2.0";
        fixture.Catalog = Catalog(templates: Encoding.UTF8.GetBytes(updated.ToJsonString()));
        var error = await Assert.ThrowsAsync<ShouException>(() => fixture.Cleanup.ConfirmAsync(plan.Id, new Confirmation()));
        Assert.Equal("plan_stale", error.Code);
        Assert.True(fixture.Files.Entries.ContainsKey(selected.Path.Value));
    }

    [Fact]
    public async Task AllRootsRegisterBeforeBatchEvidenceAndShareOneScanBudget()
    {
        var fixture = new Fixture(); fixture.Project("Projects"); fixture.Project("Code");
        var result = await fixture.Locations.ScanAsync(fixture.Scans, true, new());
        Assert.Equal("complete", result.State); Assert.Equal(2, result.Scans.Length);
        var current = await fixture.Configuration.ReadAsync();
        Assert.All(result.Scans, scan => Assert.Equal(current.Revision, scan.ConfigurationRevision));
        var partial = await fixture.Locations.ScanAsync(fixture.Scans, true, new(MaxEntries: 4));
        Assert.Equal("partial", partial.State); Assert.Single(partial.Scans);
        Assert.Contains(partial.Issues, issue => issue.Code == "resource_limit");
        Assert.Equal(4, partial.Scans.Sum(value => value.Scan.Entries.Length));
        Assert.Equal(8, fixture.Files.Entries.Count);
    }

    [Fact]
    public async Task PreCancelledDiscoveryAndPreparationNeverRegisterAnything()
    {
        var fixture = new Fixture(); fixture.Project("Projects");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Locations.DiscoverAsync(true, cancelled.Token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Locations.PrepareAsync(true, cancelled.Token));
        Assert.Empty(fixture.Store.Records);
    }

    private sealed class BatchClock : TimeProvider
    {
        public long Timestamp;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => Timestamp;
    }
    private sealed class BatchScanner(IStorageScanner scanner, Func<int, Task>? before = null) : IStorageScanner
    {
        public readonly List<ScanBudget> Budgets = [];
        public async Task<ScanSnapshot> ScanAsync(WindowsPath root, ScanBudget budget, IProgress<ScanProgress>? progress, CancellationToken cancellationToken)
        {
            Budgets.Add(budget);
            if (before is not null) await before(Budgets.Count);
            return await scanner.ScanAsync(root, budget, progress, cancellationToken);
        }
    }
    private static CleanupScanService BatchScans(Fixture fixture, IStorageScanner scanner) =>
        new(fixture.Store, Validator, scanner, fixture.Protection, catalog: fixture.Catalog);

    [Fact]
    public async Task RegisteredBatchDoesNotDiscoverOrExpandItsExplicitScope()
    {
        var fixture = new Fixture(); fixture.Project("Projects"); fixture.Project("Code");
        var chosen = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Projects"), "chosen");
        var extra = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Code"), "extra");
        await fixture.Configuration.SetExclusionAsync(chosen.Id, "**/keep", false);
        chosen = (await fixture.Configuration.ReadAsync()).Workspaces.Single(workspace => workspace.Id == chosen.Id);
        var before = fixture.Store.Records["configuration"].ToArray();
        var batch = await fixture.Locations.ScanRegisteredAsync(fixture.Scans, [chosen.Id], new());
        Assert.Equal("complete", batch.State); Assert.True(chosen.SameRegistration(Assert.Single(batch.Scans).Workspace));
        Assert.Equal(before, fixture.Store.Records["configuration"]);
        Assert.DoesNotContain(batch.Scans, scan => scan.WorkspaceId == extra.Id);
        Assert.Equal(8, fixture.Files.Entries.Count);
        Assert.DoesNotContain(fixture.Store.Records.Keys, key => key.StartsWith("plan_", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("empty")]
    [InlineData("duplicate")]
    [InlineData("missing")]
    public async Task InvalidRegisteredBatchScopeNeverStartsReadingTargets(string kind)
    {
        var fixture = new Fixture(); fixture.Project("Projects");
        var chosen = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Projects"), "chosen");
        var scanner = new BatchScanner(new StorageScanner(fixture.Files));
        var ids = kind == "empty" ? System.Collections.Immutable.ImmutableArray<string>.Empty : kind == "duplicate" ? [chosen.Id, chosen.Id] : new[] { RecordKey.New("ws") }.ToImmutableArray();
        var error = await Assert.ThrowsAsync<ShouException>(() => fixture.Locations.ScanRegisteredAsync(BatchScans(fixture, scanner), ids, new()));
        Assert.Equal(kind == "missing" ? "plan_stale" : "invalid_argument", error.Code);
        Assert.Empty(scanner.Budgets);
    }

    [Fact]
    public async Task RegisteredBatchSharesEntriesAcrossRootsAndNamesEveryUnstartedRoot()
    {
        var fixture = new Fixture(); fixture.Project("Projects"); fixture.Project("Code");
        var first = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Projects"), "first");
        var second = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Code"), "second");
        var batch = await fixture.Locations.ScanRegisteredAsync(fixture.Scans, [first.Id, second.Id], new(MaxEntries: 4));
        Assert.Equal("partial", batch.State); Assert.Single(batch.Scans);
        Assert.Equal(4, batch.Scans.Sum(scan => scan.Scan.Entries.Length));
        Assert.Contains(new ScanIssue(second.Path, "resource_limit"), batch.Issues);
    }

    [Fact]
    public async Task AStoppedRegisteredBatchRetainsEarlierPublishedSnapshotsWithoutStartingLaterRoots()
    {
        var fixture = new Fixture(); fixture.Project("Projects"); fixture.Project("Code"); fixture.Project("repos");
        var roots = new[] { "Projects", "Code", "repos" };
        var locations = new List<Workspace>();
        foreach (var root in roots) locations.Add(await fixture.Configuration.AddWorkspaceAsync(Home.Append(root), root.ToLowerInvariant()));
        using var stop = new CancellationTokenSource();
        var scanner = new BatchScanner(new StorageScanner(fixture.Files), call => { if (call == 2) stop.Cancel(); return Task.CompletedTask; });
        var batch = await fixture.Locations.ScanRegisteredAsync(BatchScans(fixture, scanner), locations.Select(value => value.Id).ToImmutableArray(), new(), stop.Token);
        Assert.Equal("cancelled", batch.State); Assert.Equal(locations[0], Assert.Single(batch.Scans).Workspace);
        Assert.Equal(2, scanner.Budgets.Count);
        Assert.All(locations.Skip(1), location => Assert.Contains(new ScanIssue(location.Path, "cancelled"), batch.Issues));
        Assert.True(fixture.Store.Records.ContainsKey(batch.Scans[0].Id));
    }

    [Fact]
    public async Task RegisteredBatchUsesOneMonotonicDeadlineForEveryLocation()
    {
        var fixture = new Fixture(); fixture.Project("Projects"); fixture.Project("Code");
        var first = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Projects"), "first");
        var second = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Code"), "second");
        var clock = new BatchClock();
        var scanner = new BatchScanner(new StorageScanner(fixture.Files), _ => { clock.Timestamp += TimeSpan.FromSeconds(2).Ticks; return Task.CompletedTask; });
        var service = new ScanLocationService(fixture.Configuration, fixture.Catalog, fixture.Files, Owner, clock);
        var batch = await service.ScanRegisteredAsync(BatchScans(fixture, scanner), [first.Id, second.Id], new(MaxDuration: TimeSpan.FromSeconds(1)));
        Assert.Equal("partial", batch.State); Assert.Single(scanner.Budgets);
        Assert.Contains(new ScanIssue(second.Path, "time_limit"), batch.Issues);
    }

    [Fact]
    public async Task FailedPublicationCannotReuseAnUnknownRemainingEntryAllowance()
    {
        var fixture = new Fixture(); fixture.Project("Projects"); fixture.Project("Code");
        var first = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Projects"), "first");
        var second = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Code"), "second");
        var scanner = new BatchScanner(new StorageScanner(fixture.Files), _ => throw new IOException("private diagnostic"));
        var batch = await fixture.Locations.ScanRegisteredAsync(BatchScans(fixture, scanner), [first.Id, second.Id], new());
        Assert.Equal("partial", batch.State); Assert.Empty(batch.Scans); Assert.Single(scanner.Budgets);
        Assert.Contains(new ScanIssue(first.Path, "io_error"), batch.Issues);
        Assert.Contains(new ScanIssue(second.Path, "resource_limit"), batch.Issues);
    }

    [Fact]
    public async Task ConfigurationChangesStopBatchPublicationAndFurtherScanning()
    {
        var fixture = new Fixture(); fixture.Project("Projects"); fixture.Project("Code");
        var first = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Projects"), "first");
        var second = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Code"), "second");
        var scanner = new BatchScanner(new StorageScanner(fixture.Files), async _ => { await fixture.Configuration.SetExclusionAsync(null, "**/keep", false); });
        var batch = await fixture.Locations.ScanRegisteredAsync(BatchScans(fixture, scanner), [first.Id, second.Id], new());
        Assert.Equal("partial", batch.State); Assert.Empty(batch.Scans); Assert.Single(scanner.Budgets);
        Assert.All(new[] { first, second }, workspace => Assert.Contains(new ScanIssue(workspace.Path, "plan_stale"), batch.Issues));
    }

    [Fact]
    public async Task PreCancelledRegisteredBatchNeverCreatesASnapshot()
    {
        var fixture = new Fixture(); fixture.Project("Projects");
        var chosen = await fixture.Configuration.AddWorkspaceAsync(Home.Append("Projects"), "chosen");
        using var stop = new CancellationTokenSource(); stop.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Locations.ScanRegisteredAsync(fixture.Scans, [chosen.Id], new(), stop.Token));
        Assert.Single(fixture.Store.Records);
    }
    [Fact]
    public async Task StandardDiscoveryIncludesArbitraryNamesAndCustomScopeDoesNotScanOldRoots()
    {
        var f = new Fixture();
        f.Project("客户工程"); f.Project("Other");
        var standard = await f.Locations.PrepareAsync(true);
        Assert.Contains(standard.Workspaces, root => root.Path == Home.Append("客户工程"));
        var custom = await f.Locations.PrepareAsync(true, scope: new(CleanupScanMode.Folders, [Home.Append("Other")]));
        Assert.Single(custom.Workspaces);
        Assert.Equal(Home.Append("Other"), custom.Workspaces[0].Path);
        var saved = await f.Configuration.ReadAsync();
        Assert.Contains(saved.Workspaces, root => root.Path == Home.Append("客户工程"));
    }

    [Fact]
    public async Task DiscoverySplitsAroundSavedPoliciesAndRejectsNestedScopeOrInjectedChildren()
    {
        var f = new Fixture();
        f.Files.Add(Home.Append("Projects").Value, EntryKind.Directory);
        f.Project("Projects/Saved"); f.Project("Projects/Sibling");
        await f.Configuration.AddWorkspaceAsync(Home.Append("Projects/Saved"), "saved");
        f.Files.InjectedChildren.Add(new(WindowsPath.Parse("D:/injected"), new(1, new string('f', 32), Owner), EntryKind.Directory, 0, 0,
            DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch));
        var found = await f.Locations.DiscoverAsync(true);
        Assert.Contains(found.Locations, root => root.Path == Home.Append("Projects/Saved") && root.WorkspaceId is not null);
        Assert.Contains(found.Locations, root => root.Path == Home.Append("Projects/Sibling") && root.State == "available");
        Assert.DoesNotContain(found.Locations, root => root.Path == WindowsPath.Parse("D:/injected"));
        Assert.Contains(found.Locations, root => root.Issue == "source_changed");
        var nested = await f.Locations.DiscoverAsync(true, scope: new(CleanupScanMode.Folders, [Home.Append("Projects/Saved/target")]));
        Assert.DoesNotContain(nested.Locations, root => root.State == "available");
        Assert.Contains(nested.Locations, root => root.Issue == "saved_scope_required");
    }
}
