using System.Text;
using System.Text.Json.Nodes;

namespace Shou.Windows.Core.Tests;

public sealed class CleanupScannerTests
{
    private sealed class DelayedRoot : IWindowsFileSystem
    {
        public async ValueTask<FileEntry> InspectAsync(WindowsPath path, CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.Infinite, cancellationToken);
            throw new InvalidOperationException();
        }
        public IAsyncEnumerable<DirectoryReadItem> ReadDirectoryAsync(WindowsPath directory, CancellationToken cancellationToken) =>
            throw new InvalidOperationException();
    }
    private static readonly WindowsPath Root = WindowsPath.Parse("C:/Users/Dev/Projects");
    private static CleanupRule Rule(RuleSchemaValidator validator, string pattern = "**/target")
    {
        var node = JsonNode.Parse(CleanupTests.Rule())!;
        node["match"]!["relative_patterns"] = new JsonArray(pattern);
        return validator.Parse(Encoding.UTF8.GetBytes(node.ToJsonString()));
    }
    private static CleanupService Service(CleanupTests.Fixture f) => new(f.Store, f.Validator,
        new CleanupScanner(f.Files, f.Clock), f.Protection, f.Activity, f.Mutation, f.Clock);

    [Fact]
    public async Task LiteralTargetsAndMarkersAreProbedBeforeWideSourceDirectories()
    {
        var f = await CleanupTests.Fixture.Create();
        for (var i = 0; i < 500; i++) f.Files.Add(Root.Append($"project-0/source-{i}.rs").Value);
        var service = new CleanupScanService(f.Store, f.Validator, new CleanupScanner(f.Files), f.Protection);
        var rule = Rule(f.Validator, "project-0/target");
        var scan = await service.PreviewAsync(f.Workspace.Id, Encoding.UTF8.GetBytes(rule.Definition.GetRawText()), new(40));
        var candidate = Assert.Single(scan.Candidates);
        Assert.Equal("review", candidate.State);
        Assert.Equal(4096, candidate.AllocatedBytes);
        Assert.True(scan.Scan.IsScopeComplete);
        Assert.False(scan.Scan.IsComplete);
        Assert.False(scan.Scan.IsCompleteAt(Root));
        Assert.Equal(ScanScope.RuleTargets, scan.Scan.Scope);
        Assert.Equal([Root.Append("project-0/target").Value], f.Files.Enumerated);
        var page = await service.ResultsAsync(scan.Id);
        Assert.Equal("complete", page.State);
        Assert.False(page.TreeComplete);
        Assert.Equal(candidate.ManifestDigest, Assert.Single(page.Candidates).ManifestDigest);
        Assert.Equal(505, f.Files.Entries.Count);
        Assert.Equal("comparison_unavailable", (await Assert.ThrowsAsync<ShouException>(() =>
            new StorageComparisonService(f.Store).SaveAsync(scan.Scan, default))).Code);
    }

    [Fact]
    public async Task AnOversizedFirstTargetCannotConsumeTheLaterTargetsQuota()
    {
        var f = await CleanupTests.Fixture.Create(2);
        for (var i = 0; i < 200; i++) f.Files.Add(Root.Append($"project-0/target/build-{i}.bin").Value);
        var scan = await new CleanupScanner(f.Files).ScanCleanupAsync(Root, [Rule(f.Validator, "*/target")], new(100), null, null, default);
        Assert.Equal(ScanState.Partial, scan.State);
        Assert.False(scan.IsCompleteAt(Root.Append("project-0/target")));
        Assert.True(scan.IsCompleteAt(Root.Append("project-1/target")));
        Assert.Contains(scan.Issues, issue => issue.Code == "entry_limit");
        Assert.True(scan.Entries.Length <= 100);
    }

    [Theory]
    [InlineData("full_tree")]
    [InlineData("unknown_scope")]
    public async Task SavedSparseEvidenceCannotClaimWholeTreeCoverage(string scope)
    {
        var f = await CleanupTests.Fixture.Create();
        var service = new CleanupScanService(f.Store, f.Validator, new CleanupScanner(f.Files), f.Protection);
        var scan = await service.ScanAsync(f.Workspace.Id, new());
        var saved = JsonNode.Parse(f.Store.Records[scan.Id])!;
        saved["scan"]!["scope"] = scope;
        f.Store.Records[scan.Id] = Encoding.UTF8.GetBytes(saved.ToJsonString());
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => service.ResultsAsync(scan.Id))).Code);
    }

    [Fact]
    public async Task SelectedPlanAndExecutionInspectOnlyBoundPathsAndTheirContext()
    {
        var f = await CleanupTests.Fixture.Create(2);
        var scan = await f.Scans.ScanAsync(f.Workspace.Id, new());
        var candidate = scan.Candidates.Single(item => item.RelativePath == "project-1/target");
        for (var i = 0; i < 500; i++) f.Files.Add(Root.Append($"source-{i}.rs").Value);
        var retained = f.Files.Entries.Where(pair => !pair.Key.StartsWith(candidate.Path.Value, StringComparison.Ordinal)).ToArray();
        f.Files.Enumerated.Clear();
        var service = Service(f);
        var plan = await service.CreatePlanAsync(scan.Id, [candidate.Id], CleanupAction.Permanent);
        var consent = await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation());
        var result = await service.ExecuteAsync(plan.Id, consent);
        Assert.Equal(CleanupExecutionState.Completed, result.State);
        Assert.All(f.Files.Enumerated, path => Assert.Equal(candidate.Path.Value, path));
        Assert.All(retained, pair => Assert.Equal(pair.Value, f.Files.Entries[pair.Key]));
        Assert.DoesNotContain(candidate.Path.Value, f.Files.Entries.Keys);
        Assert.Equal(1, f.Mutation.Calls);
    }

    [Theory]
    [InlineData("main.rs")]
    [InlineData(".env.production")]
    [InlineData("state.sqlite")]
    public async Task TargetContentsKeepTheExistingProtectedDataPolicy(string name)
    {
        var f = await CleanupTests.Fixture.Create();
        f.Files.Add(Root.Append("project-0/target/" + name).Value);
        var service = new CleanupScanService(f.Store, f.Validator, new CleanupScanner(f.Files), f.Protection);
        var scan = await service.ScanAsync(f.Workspace.Id, new());
        Assert.Contains("protected_data", Assert.Single(scan.Candidates).BlockedReasons);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => Service(f)
            .CreatePlanAsync(scan.Id, scan.Candidates.Select(item => item.Id), CleanupAction.Permanent))).Code);
        Assert.Equal(0, f.Mutation.Calls);
    }

    [Fact]
    public async Task MarkerReplacementAfterScanRejectsTheSelectedPlan()
    {
        var f = await CleanupTests.Fixture.Create();
        var scan = await f.Scans.ScanAsync(f.Workspace.Id, new());
        var marker = Root.Append("project-0/Cargo.toml");
        f.Files.Entries[marker.Value] = f.Files.Entries[marker.Value] with { Identity = new(1, new string('F', 32), f.Protection.OwnerSid) };
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => Service(f)
            .CreatePlanAsync(scan.Id, scan.Candidates.Select(item => item.Id), CleanupAction.Permanent))).Code);
        Assert.Equal(0, f.Mutation.Calls);
    }

    [Fact]
    public async Task AncestorReplacementDuringFinalVerificationErasesDependentCoverage()
    {
        var f = await CleanupTests.Fixture.Create();
        var reads = 0;
        f.Files.OnInspect = entry => entry.Path == Root && ++reads >= 4
            ? entry with { Identity = new(1, new string('F', 32), entry.Identity.OwnerSid) } : entry;
        var scan = await new CleanupScanner(f.Files).ScanCleanupAsync(Root, [Rule(f.Validator, "project-0/target")], new(), null, null, default);
        Assert.False(scan.IsCompleteAt(Root.Append("project-0/target")));
        Assert.Contains(scan.Issues, issue => issue.Path == Root && issue.Code == "directory_changed");
    }

    [Fact]
    public async Task ReparseTargetsAreReportedWithoutTraversal()
    {
        var f = await CleanupTests.Fixture.Create();
        var path = Root.Append("project-0/target");
        f.Files.Entries[path.Value] = f.Files.Entries[path.Value] with { Kind = EntryKind.ReparsePoint };
        var scan = await new CleanupScanner(f.Files).ScanCleanupAsync(Root, [Rule(f.Validator, "project-0/target")], new(), null, null, default);
        Assert.DoesNotContain(path.Value, f.Files.Enumerated);
        Assert.Empty(scan.CompletedDirectories);
        Assert.Contains(scan.Issues, issue => issue.Path == path && issue.Code == "unsupported_entry");
    }

    [Fact]
    public async Task CancellationDuringMeasurementDoesNotPublishUnverifiedTargets()
    {
        var f = await CleanupTests.Fixture.Create();
        using var stop = new CancellationTokenSource();
        f.Files.BeforeRead = (path, _) => { stop.Cancel(); return Task.CompletedTask; };
        var scan = await new CleanupScanner(f.Files).ScanCleanupAsync(Root, [Rule(f.Validator, "project-0/target")], new(), null, null, stop.Token);
        Assert.Equal(ScanState.Cancelled, scan.State);
        Assert.Empty(scan.CompletedDirectories);
    }

    [Fact]
    public async Task ExactSelectionRejectsRootsAndForeignPaths()
    {
        var f = await CleanupTests.Fixture.Create();
        foreach (var path in new[] { Root, WindowsPath.Parse("C:/Other/target") })
            Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => new CleanupScanner(f.Files)
                .ScanCleanupAsync(Root, [Rule(f.Validator)], new(), [path], null, default))).Code);
    }

    [Fact]
    public async Task RootInspectionDeadlineIsReportedAsTimeLimitWithoutUserCancellation()
    {
        var f = await CleanupTests.Fixture.Create();
        var error = await Assert.ThrowsAsync<ShouException>(() => new CleanupScanner(new DelayedRoot())
            .ScanCleanupAsync(Root, [Rule(f.Validator)], new(MaxDuration: TimeSpan.FromMilliseconds(20)), null, null, default));
        Assert.Equal("time_limit", error.Code);
    }
}
