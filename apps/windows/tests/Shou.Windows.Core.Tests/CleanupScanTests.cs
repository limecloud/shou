using System.Text;
using System.Text.Json.Nodes;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class CleanupScanTests
{
    private const string Owner = "S-1-5-21-1000";
    private static readonly WindowsPath Root = WindowsPath.Parse("C:/Users/Dev/Projects");

    private sealed class Fixture
    {
        public readonly MemoryFileSystem Files = new();
        public readonly MemoryRecordStore Store = new();
        public readonly RuleSchemaValidator Validator = new(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Contracts/rule.schema.json")));
        public readonly CleanupProtectionContext Protection = new(Owner, WindowsPath.Parse("C:/Users/Dev"), WindowsPath.Parse("C:/Users/Dev/AppData/Local/Shou/Data"), [WindowsPath.Parse("C:/Windows")]);
        public ConfigurationService Configuration => new(Store, Validator, Files, Owner);
        public CleanupScanService Service => new(Store, Validator, new StorageScanner(Files), Protection);
        public Workspace Workspace = null!;
        public WindowsPath Target = null!;

        public static async Task<Fixture> Create(bool caseSensitive = false, string targetName = "target", string marker = "Cargo.toml", string project = "project")
        {
            var fixture = new Fixture();
            fixture.Files.Add(Root.Value, EntryKind.Directory);
            var parent = Root.Append(project);
            fixture.Files.Add(parent.Value, EntryKind.Directory, caseSensitive: caseSensitive);
            fixture.Files.Add(parent.Append(marker).Value);
            fixture.Target = parent.Append(targetName);
            fixture.Files.Add(fixture.Target.Value, EntryKind.Directory);
            fixture.Files.Add(fixture.Target.Append("cache.bin").Value);
            fixture.Workspace = await fixture.Configuration.AddWorkspaceAsync(Root, "developer-workspaces");
            return fixture;
        }

        public Task<CleanupScan> Preview(byte[]? rule = null, ScanBudget? budget = null, CancellationToken token = default) =>
            Service.PreviewAsync(Workspace.Id, rule ?? Rule(), budget ?? new(), token);
    }

    private static byte[] Rule(Action<JsonNode>? edit = null)
    {
        var node = JsonNode.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Examples/rust-target.rule.json")))!;
        node["platforms"] = new JsonArray("windows");
        node["conditions"]!["min_allocated_bytes"] = 0;
        edit?.Invoke(node);
        return Encoding.UTF8.GetBytes(node.ToJsonString());
    }

    [Fact]
    public async Task PreviewSavesEvidenceWithoutImportingEnablingOrChangingTargets()
    {
        var fixture = await Fixture.Create();
        var entries = fixture.Files.Entries.ToArray();
        var preview = await fixture.Preview();
        var candidate = Assert.Single(preview.Candidates);
        Assert.Equal("review", candidate.State);
        Assert.True(candidate.Complete);
        Assert.StartsWith("sha256:", candidate.ManifestDigest);
        Assert.Equal(4096, candidate.AllocatedBytes);
        Assert.Equal("project/target", candidate.RelativePath);
        Assert.Empty(preview.AnalysisIssues);
        Assert.Equal(entries, fixture.Files.Entries.ToArray());
        Assert.Empty((await fixture.Configuration.ReadAsync()).Rules);
        Assert.Empty((await fixture.Configuration.ReadAsync()).Bindings);
        var page = await fixture.Service.ResultsAsync(preview.Id);
        Assert.Equal("complete", page.State);
        Assert.False(page.ExecutionAvailable);
        var saved = Assert.Single(page.Candidates);
        Assert.Equal(candidate.Id, saved.Id);
        Assert.Equal(candidate.ManifestDigest, saved.ManifestDigest);
        Assert.Equal(candidate.Identity, saved.Identity);
        Assert.Empty(saved.BlockedReasons);
    }

    [Theory]
    [InlineData("main.cs")]
    [InlineData(".env.production")]
    [InlineData(".git")]
    [InlineData(".ssh")]
    [InlineData("secrets.key")]
    [InlineData("state.sqlite")]
    [InlineData("disk.vhdx")]
    [InlineData("package.json")]
    [InlineData(".npmrc")]
    [InlineData("id_ed25519")]
    [InlineData("script.ps1")]
    public async Task ProtectedDescendantsBlockWholeTargets(string name)
    {
        var fixture = await Fixture.Create();
        fixture.Files.Add(fixture.Target.Append(name).Value);
        var candidate = Assert.Single((await fixture.Preview()).Candidates);
        Assert.Equal("blocked", candidate.State);
        Assert.Contains("protected_data", candidate.BlockedReasons);
    }

    [Fact]
    public async Task ProtectedAncestorsCannotBeBypassedWithANestedTarget()
    {
        var fixture = await Fixture.Create(project: ".git");
        Assert.Contains("protected_data", Assert.Single((await fixture.Preview()).Candidates).BlockedReasons);
    }

    [Theory]
    [InlineData(false, "TARGET", "CARGO.TOML", true, false)]
    [InlineData(true, "TARGET", "Cargo.toml", false, false)]
    [InlineData(true, "target", "CARGO.TOML", true, true)]
    [InlineData(true, "target", "Cargo.toml", true, false)]
    public async Task MatchingUsesEachParentDirectoryCaseBehavior(bool sensitive, string target, string marker, bool found, bool missingMarker)
    {
        var fixture = await Fixture.Create(sensitive, target, marker);
        var candidates = (await fixture.Preview()).Candidates;
        Assert.Equal(found ? 1 : 0, candidates.Length);
        if (found) Assert.Equal(missingMarker, candidates[0].BlockedReasons.Contains("project_marker_missing"));
    }

    [Theory]
    [InlineData(false, "**/cache.bin")]
    [InlineData(true, "project")]
    [InlineData(true, "**/target")]
    public async Task GlobalAndWorkspaceExclusionsProtectDescendantsAndAncestors(bool workspace, string pattern)
    {
        var fixture = await Fixture.Create();
        await fixture.Configuration.SetExclusionAsync(workspace ? fixture.Workspace.Id : null, pattern, false);
        var preview = await fixture.Preview();
        Assert.Contains("excluded", Assert.Single(preview.Candidates).BlockedReasons);
        Assert.Equal((await fixture.Configuration.ReadAsync()).Revision, preview.ConfigurationRevision);
    }

    [Fact]
    public async Task RuleExclusionOfOneDescendantBlocksTheWholeDirectory()
    {
        var fixture = await Fixture.Create();
        var rule = Rule(node => node["exclude"]!["relative_patterns"] = new JsonArray("**/cache.bin"));
        Assert.Contains("excluded", Assert.Single((await fixture.Preview(rule)).Candidates).BlockedReasons);
    }

    [Fact]
    public async Task RetentionUsesTheNewestDescendantAndSizeUsesMeasuredAllocation()
    {
        var fixture = await Fixture.Create();
        var file = fixture.Target.Append("cache.bin");
        fixture.Files.Entries[file.Value] = fixture.Files.Entries[file.Value] with { LastWriteUtc = DateTimeOffset.UtcNow };
        var preview = await fixture.Preview(Rule(node => node["conditions"]!["min_allocated_bytes"] = 8192));
        var candidate = Assert.Single(preview.Candidates);
        Assert.Contains("newer_than_retention", candidate.BlockedReasons);
        Assert.Contains("below_minimum_size", candidate.BlockedReasons);
        Assert.Equal(fixture.Files.Entries[file.Value].LastWriteUtc, candidate.NewestModifiedAt);
    }

    [Theory]
    [InlineData("owner", "foreign_owner")]
    [InlineData("hardlink", "multiple_links")]
    [InlineData("reparse", "unsupported_entry")]
    public async Task UnsupportedOwnershipLinksAndKindsNeverBecomeReviewable(string change, string reason)
    {
        var fixture = await Fixture.Create();
        var file = fixture.Target.Append("cache.bin");
        var entry = fixture.Files.Entries[file.Value];
        fixture.Files.Entries[file.Value] = change switch
        {
            "owner" => entry with { Identity = new(entry.Identity.VolumeSerialNumber, entry.Identity.FileId, "S-1-5-21-2000") },
            "hardlink" => entry with { LinkCount = 2 },
            _ => entry with { Kind = EntryKind.ReparsePoint }
        };
        var preview = await fixture.Preview();
        Assert.Contains(reason, Assert.Single(preview.Candidates).BlockedReasons);
        Assert.Equal("blocked", preview.Candidates[0].State);
    }

    [Fact]
    public async Task PartialSiblingDoesNotInvalidateIndependentCompleteTarget()
    {
        var fixture = await Fixture.Create();
        var other = Root.Append("unavailable");
        fixture.Files.Add(other.Value, EntryKind.Directory);
        fixture.Files.Denied.Add(other.Value);
        var preview = await fixture.Preview();
        Assert.Equal(ScanState.Partial, preview.Scan.State);
        var candidate = Assert.Single(preview.Candidates);
        Assert.True(candidate.Complete);
        Assert.Equal("review", candidate.State);
        Assert.Equal("partial", (await fixture.Service.ResultsAsync(preview.Id)).State);
    }

    [Fact]
    public async Task IncompleteTargetsKeepEvidenceButCannotBecomeReviewable()
    {
        var fixture = await Fixture.Create();
        fixture.Files.Denied.Add(fixture.Target.Value);
        var preview = await fixture.Preview();
        var candidate = Assert.Single(preview.Candidates);
        Assert.False(candidate.Complete);
        Assert.Null(candidate.ManifestDigest);
        Assert.Contains("coverage_incomplete", candidate.BlockedReasons);
        Assert.False((await fixture.Service.ResultsAsync(preview.Id)).ExecutionAvailable);
    }

    [Fact]
    public async Task ReplacedRootOrChangedConfigurationCannotBeSavedAsCurrentEvidence()
    {
        var fixture = await Fixture.Create();
        fixture.Files.Entries[Root.Value] = fixture.Files.Entries[Root.Value] with { Identity = new(1, 1234.ToString("x32"), Owner) };
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => fixture.Preview())).Code);
        fixture = await Fixture.Create();
        var changed = false;
        fixture.Files.BeforeRead = async (_, _) =>
        {
            if (changed) return;
            changed = true;
            await fixture.Configuration.SetExclusionAsync(null, "**/keep", false);
        };
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => fixture.Preview())).Code);
        Assert.Single(fixture.Store.Records);
    }

    [Fact]
    public async Task PagingIsStableAndBoundToTheSavedScanBytes()
    {
        var fixture = await Fixture.Create();
        fixture.Files.Add(Root.Append("another").Value, EntryKind.Directory);
        fixture.Files.Add(Root.Append("another/Cargo.toml").Value);
        fixture.Files.Add(Root.Append("another/target").Value, EntryKind.Directory);
        var preview = await fixture.Preview();
        var first = await fixture.Service.ResultsAsync(preview.Id, 1);
        Assert.Equal(2, first.CandidateCount);
        Assert.NotNull(first.NextCursor);
        var second = await fixture.Service.ResultsAsync(preview.Id, 1, first.NextCursor);
        Assert.Null(second.NextCursor);
        Assert.NotEqual(first.Candidates[0].Id, second.Candidates[0].Id);
        Assert.Equal(second.Candidates[0].Id, (await fixture.Service.ResultsAsync(preview.Id, 1, first.NextCursor)).Candidates[0].Id);
        var another = await fixture.Preview();
        Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ResultsAsync(another.Id, 1, first.NextCursor))).Code);
        fixture.Store.Records[preview.Id] = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(fixture.Store.Records[preview.Id]) + " ");
        Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ResultsAsync(preview.Id, 1, first.NextCursor))).Code);
    }

    [Theory]
    [InlineData("authorization")]
    [InlineData("rule")]
    [InlineData("candidate-path")]
    [InlineData("candidate-state")]
    [InlineData("missing-coverage")]
    [InlineData("missing-parent")]
    [InlineData("false-completeness")]
    [InlineData("coverage-gap")]
    public async Task CorruptSavedRecordsAreRejected(string mutation)
    {
        var fixture = await Fixture.Create();
        var preview = await fixture.Preview();
        var node = JsonNode.Parse(fixture.Store.Records[preview.Id])!;
        switch (mutation)
        {
            case "authorization": node["approved"] = true; break;
            case "rule": node["rules"]![0]!["definition"]!["scope"]!["follow_symlinks"] = true; break;
            case "candidate-path": node["candidates"]![0]!["path"] = "C:/Outside"; break;
            case "candidate-state": node["candidates"]![0]!["state"] = "executable"; break;
            case "missing-coverage": node["scan"]!.AsObject().Remove("completed_directories"); break;
            case "missing-parent": node["scan"]!["entries"]!.AsArray().RemoveAt(1); break;
            case "false-completeness": node["scan"]!["completed_directories"]!.AsArray().RemoveAt(2); break;
            case "coverage-gap": node["scan"]!["issues"]!.AsArray().Add(new JsonObject { ["path"] = fixture.Target.Value, ["code"] = "read_failed" }); break;
        }
        fixture.Store.Records[preview.Id] = Encoding.UTF8.GetBytes(node.ToJsonString());
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ResultsAsync(preview.Id))).Code);
    }

    [Fact]
    public async Task FailedPublicationAndCancellationDoNotCreateSnapshots()
    {
        var fixture = await Fixture.Create();
        fixture.Store.FailWrite = true;
        Assert.Equal("io_error", (await Assert.ThrowsAsync<ShouException>(() => fixture.Preview())).Code);
        Assert.Single(fixture.Store.Records);
        fixture.Store.FailWrite = false;
        using var cancellation = new CancellationTokenSource();
        fixture.Files.BeforeRead = (_, _) => { cancellation.Cancel(); return Task.CompletedTask; };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Preview(token: cancellation.Token));
        Assert.Single(fixture.Store.Records);
    }

    [Fact]
    public async Task AnalysisBudgetIsReportedWithoutGrantingExecution()
    {
        var fixture = await Fixture.Create();
        var configuration = await fixture.Configuration.ReadAsync();
        var scan = await new StorageScanner(fixture.Files).ScanAsync(Root, new(), null, default);
        var preview = new RuleClassifier(fixture.Protection).Classify(configuration, fixture.Workspace,
            fixture.Validator.Parse(Rule()), scan, new(TimeSpan.Zero), default);
        Assert.Empty(preview.Candidates);
        Assert.Equal("time_limit", Assert.Single(preview.AnalysisIssues).Code);
    }
}
