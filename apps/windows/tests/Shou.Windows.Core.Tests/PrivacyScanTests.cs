using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class PrivacyScanTests
{
    private const string Owner = "S-1-5-21-1000";
    private static readonly string Hash = "sha256:" + new string('a', 64);
    private static readonly WindowsUserDirectories Directories = new(WindowsPath.Parse("C:/Users/Dev"), WindowsPath.Parse("D:/Local"), WindowsPath.Parse("E:/Roaming"));

    internal sealed class Fixture : IPrivacyDatabaseInspection, IPrivacyBrowserActivity
    {
        public readonly MemoryFileSystem Files = new();
        public readonly MemoryRecordStore Store = new();
        public readonly CleanupTests.TestClock Clock = new();
        public readonly WindowsPrivacySourcePolicy Policy = new(Directories);
        public readonly RuleSchemaValidator Validator = new(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Contracts/rule.schema.json")));
        public long Count = 3;
        public int DatabaseCalls, ActivityCalls;
        public ActivityState Activity = ActivityState.Idle;
        public Action? OnDatabase;
        public Func<PrivacyDatabaseObservation, PrivacyDatabaseObservation>? Alter;
        public Exception? DatabaseError;
        public PrivacyScanService Service => MakeService();
        public PrivacyScanService MakeService(TimeProvider? clock = null, WindowsPath? data = null) =>
            new(Store, Validator, Policy, Files, this, this, Owner, Directories.Home, data ?? Directories.LocalAppData.Append("Shou/Data"), clock ?? Clock);
        public PrivacySourceDefinition Add(PrivacyBrowser browser = PrivacyBrowser.Chrome, string profile = "Default", PrivacyDatabaseLocation location = PrivacyDatabaseLocation.History)
        {
            var source = Policy.Create(browser, profile, location);
            var directories = new Stack<WindowsPath>();
            for (var current = source.Path.Parent; current is not null; current = current.Parent) directories.Push(current);
            foreach (var directory in directories)
                if (!Files.Entries.ContainsKey(directory.Value)) Files.Add(directory.Value, EntryKind.Directory);
            Files.Add(source.Path.Value);
            return source;
        }
        public PrivacyDatabaseObservation Observation(PrivacySourceDefinition source)
        {
            var anchor = Policy.Validate(source).Anchor;
            var evidence = Files.Entries.Values.Where(entry => entry.Path == source.Path || entry.Kind == EntryKind.Directory &&
                entry.Path.IsWithin(anchor, caseSensitive: true) && source.Path.IsWithin(entry.Path, caseSensitive: true, includeRoot: false))
                .OrderBy(entry => entry.Path.Value, StringComparer.Ordinal).Select(entry => new PrivacyFileEvidence(entry, Hash)).ToImmutableArray();
            return new(Count, Hash, evidence);
        }
        public Task<PrivacyDatabaseObservation> InspectAsync(PrivacySourceDefinition source, PrivacyWindow window, CancellationToken token)
        {
            token.ThrowIfCancellationRequested(); DatabaseCalls++; OnDatabase?.Invoke();
            if (DatabaseError is not null) throw DatabaseError;
            var observation = Observation(source);
            return Task.FromResult(Alter?.Invoke(observation) ?? observation);
        }
        public Task<ActivityObservation> InspectAsync(PrivacyBrowser browser, CancellationToken token)
        { token.ThrowIfCancellationRequested(); ActivityCalls++; return Task.FromResult(new ActivityObservation(Activity)); }
        public void Configure(ImmutableArray<string> exclusions = default, ImmutableArray<Workspace> workspaces = default)
        {
            var configuration = Configuration.Empty with { Revision = RecordKey.New("config"), GlobalExclusions = exclusions.IsDefault ? [] : exclusions,
                Workspaces = workspaces.IsDefault ? [] : workspaces };
            Store.Records["configuration"] = new ConfigurationCodec(Validator).Encode(configuration);
        }
    }

    [Theory]
    [InlineData(PrivacyBrowser.Chrome, PrivacyDatabaseLocation.History, "Google/Chrome/User Data/Default/History")]
    [InlineData(PrivacyBrowser.Chromium, PrivacyDatabaseLocation.NetworkCookies, "Chromium/User Data/Default/Network/Cookies")]
    [InlineData(PrivacyBrowser.Edge, PrivacyDatabaseLocation.LegacyCookies, "Microsoft/Edge/User Data/Default/Cookies")]
    [InlineData(PrivacyBrowser.Brave, PrivacyDatabaseLocation.History, "BraveSoftware/Brave-Browser/User Data/Default/History")]
    [InlineData(PrivacyBrowser.Firefox, PrivacyDatabaseLocation.FirefoxCookies, "Mozilla/Firefox/Profiles/Default/cookies.sqlite")]
    public void FixedSourcesUseActualRedirectedAppData(PrivacyBrowser browser, PrivacyDatabaseLocation location, string relative)
    {
        var policy = new WindowsPrivacySourcePolicy(Directories); var source = policy.Create(browser, "Default", location);
        Assert.Equal((browser == PrivacyBrowser.Firefox ? Directories.RoamingAppData : Directories.LocalAppData).Append(relative), source.Path);
        Assert.Equal(source, policy.Create(browser, "Default", location)); Assert.NotNull(policy.Validate(source));
        Assert.Throws<ShouException>(() => policy.Validate(source with { Path = source.Path.Parent!.Append("Other") }));
        Assert.Throws<ShouException>(() => policy.Validate(source with { Id = RecordKey.New("privacy_source") }));
    }

    [Theory]
    [InlineData("../Default")]
    [InlineData("Guest Profile")]
    [InlineData("Profile 1234567890")]
    [InlineData("Profile 1/History")]
    [InlineData("CON")]
    [InlineData("Default.")]
    public void ChromiumProfileNamesCannotExpandSourceAuthority(string profile) =>
        Assert.Throws<ShouException>(() => new WindowsPrivacySourcePolicy(Directories).Create(PrivacyBrowser.Chrome, profile, PrivacyDatabaseLocation.History));

    [Fact]
    public void SourceKindAndBrowserCannotDisagree()
    {
        var policy = new WindowsPrivacySourcePolicy(Directories);
        Assert.Throws<ShouException>(() => policy.Create(PrivacyBrowser.Firefox, "Profile", PrivacyDatabaseLocation.History));
        Assert.Throws<ShouException>(() => policy.Create(PrivacyBrowser.Chrome, "Default", PrivacyDatabaseLocation.FirefoxCookies));
        var source = policy.Create(PrivacyBrowser.Chrome, "Profile 42", PrivacyDatabaseLocation.NetworkCookies);
        Assert.Throws<ShouException>(() => policy.Validate(source with { Kind = PrivacyDataKind.History }));
    }

    [Theory]
    [InlineData(-11, -2)]
    [InlineData(-1, -1)]
    [InlineData(1, 0)]
    [InlineData(11, 1)]
    public void IntegerTimeBoundariesRoundWithoutFloatingPoint(long ticks, long upper)
    {
        var window = PrivacyWindow.Create(PrivacyTimeRange.LastHour, DateTimeOffset.UnixEpoch.AddTicks(ticks));
        var unix = window.IntegerMicroseconds(false); var chromium = window.IntegerMicroseconds(true);
        var expectedLower = (long)decimal.Ceiling((ticks - TimeSpan.TicksPerHour) / 10m);
        Assert.Equal(upper, unix.End); Assert.Equal(expectedLower, unix.Start);
        Assert.Equal(checked(unix.End + 11_644_473_600_000_000L), chromium.End);
        Assert.Equal(checked(unix.Start + 11_644_473_600_000_000L), chromium.Start);
    }

    [Theory]
    [InlineData(PrivacyTimeRange.LastHour, 1)]
    [InlineData(PrivacyTimeRange.LastDay, 24)]
    [InlineData(PrivacyTimeRange.LastSevenDays, 168)]
    [InlineData(PrivacyTimeRange.AllTime, 0)]
    public void WindowsAreFixedAndValidated(PrivacyTimeRange range, int hours)
    {
        var end = new DateTimeOffset(2026, 10, 23, 0, 0, 0, TimeSpan.Zero); var window = PrivacyWindow.Create(range, end);
        Assert.Equal(hours == 0 ? null : end.AddHours(-hours), window.Start);
        Assert.Equal(hours == 0, window.IntegerMicroseconds(false).Start is null);
        Assert.Throws<ShouException>(() => (window with { Start = end }).Validate());
        if (window.Start is { } start) Assert.Throws<ShouException>(() => (window with { Start = start.ToOffset(TimeSpan.FromHours(1)) }).Validate());
        Assert.Throws<ShouException>(() => PrivacyWindow.Create(range, end.ToOffset(TimeSpan.FromHours(1))));
    }

    [Fact]
    public async Task ReadOnlyScanPersistsOnlyMetadataAndCanBeReadWithoutDatabaseAccess()
    {
        var f = new Fixture(); var source = f.Add(); var before = f.Files.Entries.ToArray();
        var scan = await f.Service.ScanAsync(); Assert.True(scan.Complete); Assert.Equal(3, scan.Sources[0].RecordCount);
        Assert.Equal(PrivacySourceState.Ready, scan.Sources[0].State); Assert.Equal(1, f.DatabaseCalls); Assert.Equal(2, f.ActivityCalls);
        Assert.Equal(scan.CreatedAt, scan.Window.End); Assert.Equal(TimeSpan.FromMinutes(15), scan.ExpiresAt - scan.CreatedAt);
        Assert.Equal(before, f.Files.Entries.ToArray()); Assert.Single(f.Store.Records);
        var read = await f.Service.ReadAsync(scan.Id);
        Assert.Equal(scan.Digest, read.Digest); Assert.Equal(source, read.Sources[0].Source); Assert.Equal(1, f.DatabaseCalls);
        f.Clock.Now = scan.ExpiresAt.AddDays(1);
        Assert.Equal(scan.Digest, (await f.Service.ReadAsync(scan.Id)).Digest); // Reading an expired observation grants no mutation authority.
    }

    [Theory]
    [InlineData("S-1-5-32-544")]
    [InlineData("S-1-5-18")]
    public async Task ProvisionedAppDataAnchorRetainsItsOsOwnerInReadOnlyEvidence(string owner)
    {
        var f = new Fixture(); var source = f.Add(); var anchor = f.Policy.Validate(source).Anchor;
        var entry = f.Files.Entries[anchor.Value];
        f.Files.Entries[anchor.Value] = entry with { Identity = new(entry.Identity.VolumeSerialNumber, entry.Identity.FileId, owner) };
        var scan = await f.Service.ScanAsync();
        Assert.True(scan.Complete);
        var observed = Assert.Single(scan.Sources);
        Assert.Equal(PrivacySourceState.Ready, observed.State);
        Assert.Equal(owner, observed.Evidence.Single(item => item.Entry.Path == anchor).Entry.Identity.OwnerSid);
        Assert.Equal(scan.Digest, (await f.Service.ReadAsync(scan.Id)).Digest);
        Assert.Equal(owner, f.Files.Entries[anchor.Value].Identity.OwnerSid);
    }

    [Theory]
    [InlineData("anchor", "S-1-5-21-9999")]
    [InlineData("intermediate", "S-1-5-32-544")]
    [InlineData("intermediate", "S-1-5-18")]
    [InlineData("database", "S-1-5-32-544")]
    [InlineData("database", "S-1-5-18")]
    public async Task ProvisionedAnchorExceptionCannotAuthorizeOtherOwnersOrDescendants(string target, string owner)
    {
        var f = new Fixture(); var source = f.Add(); var anchor = f.Policy.Validate(source).Anchor;
        f.Alter = observation => observation with
        {
            Evidence = observation.Evidence.Select(item => item.Entry.Path == (target == "anchor" ? anchor : target == "database" ? source.Path : anchor.Append("Google"))
                ? item with { Entry = item.Entry with { Identity = new(item.Entry.Identity.VolumeSerialNumber, item.Entry.Identity.FileId, owner) } } : item).ToImmutableArray()
        };
        var scan = await f.Service.ScanAsync();
        Assert.False(scan.Complete);
        Assert.Equal(PrivacySourceState.Unavailable, Assert.Single(scan.Sources).State);
        Assert.Null(scan.Sources[0].RecordCount);
    }

    [Fact]
    public async Task EmptyDatabaseIsACompleteEmptyObservation()
    {
        var f = new Fixture { Count = 0 }; f.Add(); var scan = await f.Service.ScanAsync();
        Assert.True(scan.Complete); Assert.Equal(PrivacySourceState.Empty, scan.Sources[0].State); Assert.Equal(0, scan.Sources[0].RecordCount);
    }

    [Fact]
    public async Task MissingRootsAreNotPermissionFailuresAndDiscoveryDoesNotReadDatabases()
    {
        var f = new Fixture(); var result = await new PrivacySourceDiscovery(f.Policy, f.Files, Owner).DiscoverAsync();
        Assert.True(result.Complete); Assert.Empty(result.Sources); Assert.Empty(result.Issues); Assert.Equal(0, f.DatabaseCalls);
    }

    [Theory]
    [InlineData("foreign_owner")]
    [InlineData("reparse")]
    [InlineData("hardlink")]
    public async Task UnsafeDatabaseMetadataCannotReachSqlite(string unsafeKind)
    {
        var f = new Fixture(); var source = f.Add(); var entry = f.Files.Entries[source.Path.Value];
        f.Files.Entries[source.Path.Value] = unsafeKind switch
        {
            "foreign_owner" => entry with { Identity = new(entry.Identity.VolumeSerialNumber, entry.Identity.FileId, "S-1-5-21-9999") },
            "reparse" => entry with { Kind = EntryKind.ReparsePoint }, _ => entry with { LinkCount = 2 }
        };
        var scan = await f.Service.ScanAsync(); Assert.False(scan.Complete); Assert.Empty(scan.Sources); Assert.NotEmpty(scan.Issues); Assert.Equal(0, f.DatabaseCalls);
    }

    [Theory]
    [InlineData("root")]
    [InlineData("profile")]
    public async Task ChangedDiscoveryIdentityDoesNotPublishTheRoot(string changed)
    {
        var f = new Fixture(); var source = f.Add(); var root = f.Policy.Validate(source).Path; var profile = source.Path.Parent!;
        var reads = 0;
        f.Files.OnInspect = entry => entry.Path == (changed == "root" ? root : profile) && ++reads > (changed == "root" ? 1 : 0)
            ? entry with { Identity = new(1, new string('f', 32), Owner) } : entry;
        var discovery = await new PrivacySourceDiscovery(f.Policy, f.Files, Owner).DiscoverAsync();
        Assert.False(discovery.Complete); Assert.Empty(discovery.Sources); Assert.Contains(discovery.Issues, issue => issue.Code == "source_changed");
    }

    [Fact]
    public async Task DiscoveryKeepsOtherRootsAfterAPermissionGap()
    {
        var f = new Fixture(); var first = f.Add(); var second = f.Add(PrivacyBrowser.Edge);
        f.Files.Denied.Add(f.Policy.Validate(first).Path.Value);
        var discovery = await new PrivacySourceDiscovery(f.Policy, f.Files, Owner).DiscoverAsync();
        Assert.False(discovery.Complete); Assert.Equal(second, Assert.Single(discovery.Sources));
        Assert.Contains(discovery.Issues, issue => issue.Browser == PrivacyBrowser.Chrome && issue.Code == "permission_denied");
    }

    [Fact]
    public async Task DiscoveryBoundsProfileMetadataWithoutTruncatingToACompleteResult()
    {
        var f = new Fixture(); for (var index = 0; index <= PrivacySourceDiscovery.MaximumProfiles; index++) f.Add(profile: "Profile " + index);
        var result = await new PrivacySourceDiscovery(f.Policy, f.Files, Owner).DiscoverAsync();
        Assert.False(result.Complete); Assert.Contains(result.Issues, issue => issue.Code == "privacy_source_limit"); Assert.Empty(result.Sources);
    }

    [Theory]
    [InlineData(ActivityState.Active, PrivacySourceState.BrowserRunning)]
    [InlineData(ActivityState.Unknown, PrivacySourceState.ActivityUnknown)]
    public async Task BrowserMustBeObservedIdleBeforeReading(ActivityState activity, PrivacySourceState state)
    {
        var f = new Fixture { Activity = activity }; f.Add(); var scan = await f.Service.ScanAsync();
        Assert.False(scan.Complete); Assert.Equal(state, scan.Sources[0].State); Assert.Null(scan.Sources[0].RecordCount); Assert.Empty(scan.Sources[0].Evidence); Assert.Equal(0, f.DatabaseCalls);
    }

    [Fact]
    public async Task BrowserStartingDuringTheQueryDiscardsItsCountAndEvidence()
    {
        var f = new Fixture(); f.Add(); f.OnDatabase = () => f.Activity = ActivityState.Active;
        var scan = await f.Service.ScanAsync(); Assert.False(scan.Complete); Assert.Equal(PrivacySourceState.ActivityUnknown, scan.Sources[0].State);
        Assert.Null(scan.Sources[0].RecordCount); Assert.Empty(scan.Sources[0].Evidence);
    }

    [Theory]
    [InlineData("Google/Chrome")]
    [InlineData("**/History")]
    [InlineData("**/History-wal")]
    [InlineData("**/History-shm")]
    [InlineData("**/History-journal")]
    public async Task GlobalProtectionIncludesAncestorsAndAllSqliteSidecars(string pattern)
    {
        var f = new Fixture(); f.Add(); f.Configure([pattern]); var scan = await f.Service.ScanAsync();
        Assert.Equal(PrivacySourceState.Excluded, scan.Sources[0].State); Assert.Equal(0, f.DatabaseCalls); Assert.False(scan.Complete);
    }

    [Fact]
    public async Task MatchingWorkspaceExclusionsAndShouStorageAreProtected()
    {
        var f = new Fixture(); var source = f.Add(); var directory = f.Policy.Validate(source).Path; var entry = f.Files.Entries[directory.Value];
        f.Configure(workspaces: [new(RecordKey.New("ws"), "browser", directory, entry.Identity, false, ["**/History-wal"], f.Clock.Now)]);
        Assert.Equal(PrivacySourceState.Excluded, (await f.Service.ScanAsync()).Sources[0].State);
        f.Configure(); Assert.Equal(PrivacySourceState.Excluded, (await f.MakeService(data: source.Path.Parent).ScanAsync()).Sources[0].State); Assert.Equal(0, f.DatabaseCalls);
    }

    [Theory]
    [InlineData("privacy_schema_unsupported", PrivacySourceState.SchemaUnsupported)]
    [InlineData("permission_denied", PrivacySourceState.PermissionRequired)]
    [InlineData("privacy_database_busy", PrivacySourceState.Unavailable)]
    [InlineData("raw_private_value", PrivacySourceState.Unavailable)]
    public async Task FailuresPublishOnlyRedactedCodes(string code, PrivacySourceState state)
    {
        var f = new Fixture { DatabaseError = new ShouException(code, "https://private.example/record?secret=1") }; f.Add(); var scan = await f.Service.ScanAsync();
        Assert.Equal(state, scan.Sources[0].State); Assert.Equal(code == "raw_private_value" ? "read_failed" : code, scan.Sources[0].Reason);
        Assert.DoesNotContain("private.example", System.Text.Encoding.UTF8.GetString(f.Store.Records[scan.Id]));
    }

    [Theory]
    [InlineData("missing_ancestor")]
    [InlineData("foreign_owner")]
    [InlineData("cross_volume")]
    [InlineData("unrelated_path")]
    [InlineData("duplicate_identity")]
    [InlineData("negative_count")]
    [InlineData("invalid_schema_digest")]
    public async Task InvalidAdapterEvidenceCannotBecomeAReadySource(string change)
    {
        var f = new Fixture(); f.Add(); f.Alter = observation => AlterObservation(observation, change);
        var scan = await f.Service.ScanAsync(); Assert.Equal(PrivacySourceState.Unavailable, scan.Sources[0].State); Assert.Null(scan.Sources[0].RecordCount);
    }
    private static PrivacyDatabaseObservation AlterObservation(PrivacyDatabaseObservation observation, string change)
    {
        var evidence = observation.Evidence; var item = evidence[^1];
        return change switch
        {
            "missing_ancestor" => observation with { Evidence = evidence.RemoveAt(0) },
            "negative_count" => observation with { RecordCount = -1 },
            "invalid_schema_digest" => observation with { SchemaDigest = "secret" },
            _ => observation with { Evidence = evidence.SetItem(evidence.Length - 1, item with { Entry = change switch
            {
                "foreign_owner" => item.Entry with { Identity = new(1, item.Entry.Identity.FileId, "S-1-5-21-9999") },
                "cross_volume" => item.Entry with { Identity = new(2, item.Entry.Identity.FileId, Owner) },
                "duplicate_identity" => item.Entry with { Identity = evidence[0].Entry.Identity },
                _ => item.Entry with { Path = WindowsPath.Parse("D:/Unrelated") }
            } }) }
        };
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ChangedConfigurationOrClockPreventsPublication(bool clock)
    {
        var f = new Fixture(); f.Add(); f.OnDatabase = () => { if (clock) f.Clock.Now = f.Clock.Now.AddMinutes(15); else f.Configure(["**/History"]); };
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ScanAsync())).Code);
        Assert.DoesNotContain(f.Store.Records, pair => pair.Key.StartsWith("privacy_scan_", StringComparison.Ordinal));
    }

    [Fact]
    public async Task CancellationDoesNotPublishScanAndDiscoveryDeadlineIsAPartialGap()
    {
        var f = new Fixture(); f.Add(); using var stop = new CancellationTokenSource(); f.OnDatabase = stop.Cancel;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Service.ScanAsync(cancellationToken: stop.Token)); Assert.Empty(f.Store.Records);
        f.OnDatabase = null; var clock = new ManualDeadlineClock(); f.Files.BeforeRead = (_, _) => { clock.Expire(); return Task.CompletedTask; };
        var partial = await f.MakeService(clock).ScanAsync(); Assert.False(partial.Complete); Assert.Contains(partial.Issues, issue => issue.Code == "time_limit"); Assert.Empty(partial.Sources);
    }

    [Theory]
    [InlineData("version")]
    [InlineData("complete")]
    [InlineData("count")]
    [InlineData("evidence")]
    [InlineData("source")]
    [InlineData("expiry_offset")]
    [InlineData("digest")]
    [InlineData("unknown_field")]
    public async Task StrictReadRejectsTamperingEvenWhenMetadataDigestIsRecomputed(string change)
    {
        var f = new Fixture(); f.Add(); var scan = await f.Service.ScanAsync(); var source = scan.Sources[0];
        scan = change switch
        {
            "version" => scan with { Version = 2 }, "complete" => scan with { Issues = [new(null, "time_limit")] },
            "count" => scan with { Sources = [source with { RecordCount = 0 }] },
            "evidence" => scan with { Sources = [source with { Evidence = source.Evidence.RemoveAt(0) }] },
            "source" => scan with { Sources = [source with { Source = source.Source with { Path = source.Source.Path.Parent!.Append("Other") } }] },
            "expiry_offset" => scan with { ExpiresAt = scan.ExpiresAt.ToOffset(TimeSpan.FromHours(1)) }, _ => scan
        };
        scan = scan with { Digest = change == "digest" ? Hash : Digest(scan with { Digest = "" }) };
        var node = JsonSerializer.SerializeToNode(scan, ContractJson.Options)!;
        if (change == "unknown_field") node["private_values"] = new JsonArray("not-allowed");
        f.Store.Records[scan.Id] = JsonSerializer.SerializeToUtf8Bytes(node, ContractJson.Options);
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ReadAsync(scan.Id))).Code);
    }
    private static string Digest<T>(T value) => "sha256:" + Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(value, ContractJson.Options)));
}
