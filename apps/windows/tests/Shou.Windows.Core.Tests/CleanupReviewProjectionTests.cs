using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class CleanupReviewProjectionTests
{
    private static readonly WindowsPath Root = WindowsPath.Parse("C:/Users/Dev/Projects");
    private static readonly BuiltinRuleCatalog Catalog = new(new(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Contracts/rule.schema.json"))),
        new(WindowsPath.Parse("C:/Users/Dev"), WindowsPath.Parse("C:/Users/Dev/AppData/Local"), WindowsPath.Parse("C:/Users/Dev/AppData/Roaming")),
        Resource("builtin-rules"), Resource("known-locations"), Resource("project-locations"));
    private static readonly IReadOnlyDictionary<string, string> Categories = new Dictionary<string, string>
    { ["shou.builtin.output"] = "build", ["shou.builtin.dependencies"] = "dependencies", ["shou.builtin.cache"] = "cache" };
    private static byte[] Resource(string name) => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Catalog", name + ".json"));
    private static FileIdentity Identity(int id) => new(1, id.ToString("x32"), "S-1-5-21-1000");
    private static RuleCandidate Candidate(int id, string relative, string rule = "shou.builtin.output", WindowsPath? root = null, long bytes = 4096) =>
        new(RecordKey.New("candidate"), rule, "1.0.0", relative, (root ?? Root).Append(relative), Identity(id), bytes, bytes,
            DateTimeOffset.UnixEpoch, "review", true, "review", [], "sha256:" + new string('a', 64));
    private static MeasuredEntry Entry(string relative, EntryKind kind = EntryKind.File, uint links = 1, bool sensitive = false, WindowsPath? root = null) =>
        new(new((root ?? Root).Append(relative), Identity(100), kind, 0, 0, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, links, sensitive), 0);
    private static CleanupScan Scan(ImmutableArray<RuleCandidate> candidates, ImmutableArray<MeasuredEntry> entries = default,
        WindowsPath? root = null, bool sensitive = false, string? id = null)
    {
        var workspace = new Workspace(RecordKey.New("ws"), "projects", root ?? Root, Identity(1), sensitive, [], DateTimeOffset.UnixEpoch);
        var scanId = id ?? RecordKey.New("scan");
        return new(1, scanId, workspace, new(), RecordKey.New("config"), "sha256:" + new string('b', 64), [],
            new(scanId, workspace.Path, workspace.Identity, DateTimeOffset.UnixEpoch, ScanState.Complete, entries.IsDefault ? [] : entries, [], [], ScanScope.RuleTargets),
            candidates, [], false);
    }
    private static CleanupReviewProjection Project(params CleanupScan[] scans) => new(scans.ToImmutableArray(), Categories, Catalog);

    [Fact]
    public void NearestObservedProjectMarkerOwnsOutputsWithoutReadingSourceOrRepositoryState()
    {
        var scan = Scan([Candidate(1, "app/target"), Candidate(2, "app/nested/.build"), Candidate(3, "go/bin")],
            [Entry("app/Cargo.toml"), Entry("app/nested/Package.swift"), Entry("go/go.mod")]);
        var groups = Project(scan).Projects;
        Assert.Equal(new[] { "app", "app/nested", "go" }, groups.Select(group => group.Path.RelativeTo(Root)));
        Assert.All(groups, group => { Assert.True(group.IdentifiedProject); Assert.Single(group.Sources); Assert.Equal(4096, group.AllocatedBytes); });
        Assert.All(groups.SelectMany(group => group.Sources), source => Assert.Same(scan, source.Scan));
    }

    [Fact]
    public void UnknownProjectUsesScanLocationAndCountsOnlyMatchedTargets()
    {
        var scan = Scan([Candidate(1, "app/target"), Candidate(2, "app/node_modules", "shou.builtin.dependencies", bytes: 8192),
            Candidate(3, "shared/cache", "shou.builtin.cache")]);
        var group = Assert.Single(Project(scan).Projects);
        Assert.False(group.IdentifiedProject); Assert.Equal(Root, group.Path);
        Assert.Equal(2, group.Sources.Length); Assert.Equal(12_288, group.AllocatedBytes);
        Assert.Equal(3, Project(scan).Sources.Length);
    }

    [Theory]
    [InlineData(EntryKind.ReparsePoint, 1)]
    [InlineData(EntryKind.Directory, 1)]
    [InlineData(EntryKind.Unsupported, 1)]
    [InlineData(EntryKind.File, 2)]
    public void LinkedOrNonFileMarkersDoNotIdentifyAProject(EntryKind kind, uint links)
    {
        var group = Assert.Single(Project(Scan([Candidate(1, "app/target")], [Entry("app/Cargo.toml", kind, links)])).Projects);
        Assert.False(group.IdentifiedProject); Assert.Equal(Root, group.Path);
    }

    [Fact]
    public void SimilarPrefixesAndOutOfScopeMarkersDoNotClaimAnOutput()
    {
        var scan = Scan([Candidate(1, "application/target")], [Entry("app/Cargo.toml"), Entry("Cargo.toml", root: Root.Parent)]);
        var group = Assert.Single(Project(scan).Projects);
        Assert.False(group.IdentifiedProject); Assert.Equal(Root, group.Path);
    }

    [Fact]
    public void ProjectMarkersAreBoundToTheirOwnSnapshot()
    {
        var first = Scan([Candidate(1, "app/target")]);
        var second = Scan([Candidate(2, "other/target")], [Entry("app/Cargo.toml")]);
        Assert.False(Assert.Single(Project(first, second).Projects).IdentifiedProject);
    }

    [Fact]
    public void OverlappingRootsAndNestedCandidatesShareOneStableDisplayedSource()
    {
        var parent = Candidate(1, "app/target", bytes: 12_288);
        var first = Scan([parent, Candidate(2, "app/target/debug")], [Entry("app/Cargo.toml")], id: "scan_a");
        var root = Root.Append("app");
        var duplicate = Candidate(3, "target", root: root, bytes: 12_288);
        var second = Scan([duplicate], [Entry("Cargo.toml", root: root)], root: root, id: "scan_b");
        var forward = Project(first, second); var reverse = Project(second, first);
        Assert.Equal(parent.Id, Assert.Single(forward.Sources).Candidate.Id);
        Assert.Equal(parent.Id, Assert.Single(reverse.Sources).Candidate.Id);
        Assert.Equal(12_288, Assert.Single(forward.Projects).AllocatedBytes);
        Assert.Equal(first.Id, Assert.Single(Assert.Single(forward.Projects).Sources).Scan.Id);
    }

    [Theory]
    [InlineData(false, 1)]
    [InlineData(true, 2)]
    public void CaseSensitivityControlsDuplicatePathsAndProjectRoots(bool sensitive, int expected)
    {
        var scan = Scan([Candidate(1, "app/target"), Candidate(2, "App/target")],
            [Entry("app/Cargo.toml"), Entry("App/Cargo.toml")], sensitive: sensitive);
        var projection = Project(scan);
        Assert.Equal(expected, projection.Sources.Length); Assert.Equal(expected, projection.Projects.Length);
    }

    [Fact]
    public void NestedCaseSensitiveDirectoryKeepsDistinctPathsAndRejectsWrongMarkerCase()
    {
        var scan = Scan([Candidate(1, "app/target"), Candidate(2, "app/Target")],
            [Entry("app", EntryKind.Directory, sensitive: true), Entry("app/CARGO.TOML")]);
        var projection = Project(scan);
        Assert.Equal(2, projection.Sources.Length);
        Assert.False(Assert.Single(projection.Projects).IdentifiedProject);
    }

    [Fact]
    public void PersonalRulesNeedAnObservedProjectInACanonicalNonCacheScope()
    {
        var personal = Candidate(1, "app/generated", "dev.personal");
        var unknown = Candidate(2, "unknown/generated", "dev.personal");
        var scan = Scan([personal, unknown], [Entry("app/package.json")]);
        var group = Assert.Single(Project(scan).Projects);
        Assert.Equal(Root.Append("app"), group.Path);
        Assert.Equal(personal.Id, Assert.Single(group.Sources).Candidate.Id);
        Assert.Empty(new CleanupReviewProjection([scan], Categories).Projects);
    }

    [Fact]
    public void CanonicalProjectRulesIncludeProjectCachesWithoutIncludingSharedToolCaches()
    {
        var project = Candidate(1, "app/__pycache__", "shou.builtin.python-bytecode");
        var shared = Candidate(2, "shared/cache", "shou.builtin.windows-chrome");
        var scan = Scan([project, shared], [Entry("app/pyproject.toml")]);
        var categories = Catalog.Templates.ToDictionary(template => template.Id, template => template.Category);
        var group = Assert.Single(new CleanupReviewProjection([scan], categories, Catalog).Projects);
        Assert.Equal(project.Id, Assert.Single(group.Sources).Candidate.Id);
        Assert.Equal("cache", group.Sources[0].Category);
    }

    [Theory]
    [InlineData("exact")]
    [InlineData("parent")]
    [InlineData("child")]
    public void PersonalRulesInKnownCacheScopesRemainOutsideProjectsEvenWithAMarker(string overlap)
    {
        var cache = Catalog.Locations.Single(location => location.Id == "windows-chrome").Path;
        var root = overlap == "parent" ? cache.Parent! : overlap == "child" ? cache.Append("Default") : cache;
        var scan = Scan([Candidate(1, "app/generated", "dev.personal", root)], [Entry("app/package.json", root: root)], root);
        Assert.Empty(Project(scan).Projects);
    }

    [Fact]
    public void GroupingDoesNotChangeBlockedOrIncompleteCandidateEvidence()
    {
        var candidate = Candidate(1, "app/target") with { Complete = false, State = "blocked", BlockedReasons = ["protected_data"] };
        var source = Assert.Single(Assert.Single(Project(Scan([candidate], [Entry("app/Cargo.toml")])).Projects).Sources);
        Assert.Same(candidate, source.Candidate); Assert.False(source.Candidate.Complete); Assert.Equal("blocked", source.Candidate.State);
    }

    [Fact]
    public void CapacitySortIsStableAndSaturatesInsteadOfOverflowing()
    {
        var scan = Scan([Candidate(1, "small/target"), Candidate(2, "large/target", bytes: long.MaxValue), Candidate(3, "large/build")],
            [Entry("small/Cargo.toml"), Entry("large/Cargo.toml")]);
        var groups = Project(scan).Projects;
        Assert.Equal("large", groups[0].Path.Name); Assert.Equal(long.MaxValue, groups[0].AllocatedBytes); Assert.Equal(4096, groups[1].AllocatedBytes);
    }
}
