using System.Collections.Immutable;
using System.Text;
using System.Text.Json.Nodes;
using Shou.Windows.Core;
using Fixture = Shou.Windows.Core.Tests.CleanupTests.Fixture;

namespace Shou.Windows.Core.Tests;

public sealed class RustArtifactTests
{
    private sealed class Tracking : IArtifactTracking
    {
        public bool Tracked;
        public int Calls;
        public Func<CancellationToken, Task<bool>>? Read;
        public Task<bool> HasTrackedContentAsync(WindowsPath target, string ownerSid, CancellationToken token)
        { Calls++; return Read?.Invoke(token) ?? Task.FromResult(Tracked); }
    }
    private sealed class Files : ICleanupFileUse
    {
        public Task<ActivityObservation> InspectAsync(ImmutableArray<WindowsPath> paths, CancellationToken token) => Task.FromResult(new ActivityObservation(ActivityState.Idle));
    }
    private sealed class Processes : IProcessInventory
    {
        public Task<ProcessInventory> InspectAsync(ImmutableArray<string> names, CancellationToken token) => Task.FromResult(new ProcessInventory(true, []));
    }
    private sealed class VerifiedMutation(Fixture fixture, Tracking tracking) : ICleanupMutation
    {
        public bool VerifiesMutationManifest => true;
        public bool Supports(CleanupAction action) => true;
        public async Task<CleanupMutationResult> ApplyAsync(Workspace workspace, CleanupPlanItem item, CleanupAction action, CancellationToken token)
        {
            var result = await fixture.Mutation.ApplyAsync(workspace, item, action, token);
            tracking.Tracked = true;
            return result;
        }
    }
    private const string RuleId = "shou.builtin.rust-target";
    private static BuiltinRuleCatalog Catalog(Fixture f) => new(f.Validator,
        new(f.Protection.HomeDirectory, f.Protection.HomeDirectory.Append("AppData/Local"), f.Protection.HomeDirectory.Append("AppData/Roaming")),
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Catalog/builtin-rules.json")),
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Catalog/known-locations.json")),
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Catalog/project-locations.json")));
    private static CleanupScanService Scans(Fixture f) => new(f.Store, f.Validator, new CleanupScanner(f.Files, f.Clock), f.Protection, f.Clock, Catalog(f));
    private static CleanupService Service(Fixture f, Tracking? tracking, ICleanupMutation? mutation = null) => new(f.Store, f.Validator,
        new CleanupScanner(f.Files, f.Clock), f.Protection, new CleanupActivityService(new Files(), new Processes(), tracking: tracking),
        mutation ?? f.Mutation, f.Clock, Catalog(f));

    private static WindowsPath Add(Fixture f, string relative, EntryKind kind = EntryKind.File)
    {
        var path = f.Workspace.Path.Append(relative);
        for (var parent = path.Parent; parent is not null && parent.IsWithin(f.Workspace.Path, caseSensitive: true); parent = parent.Parent)
            if (!f.Files.Entries.ContainsKey(parent.Value)) f.Files.Add(parent.Value, EntryKind.Directory);
        if (!f.Files.Entries.ContainsKey(path.Value)) f.Files.Add(path.Value, kind);
        return path;
    }
    private static void Layout(Fixture f, string profile = "debug", int project = 0)
    {
        Add(f, $"project-{project}/target/CACHEDIR.TAG");
        Add(f, $"project-{project}/target/.rustc_info.json");
        Add(f, $"project-{project}/target/{profile}/.fingerprint", EntryKind.Directory);
        Add(f, $"project-{project}/target/{profile}/build/bindgen-0123456789abcdef/out/bindings.rs");
    }
    private static RuleCandidate Rust(CleanupScan scan) => Assert.Single(scan.Candidates.Where(item => item.RuleId == RuleId));

    [Theory]
    [InlineData("debug")]
    [InlineData("release")]
    [InlineData("x86_64-pc-windows-msvc/debug")]
    public async Task ExactBundledRuleRecognizesOutDirButPersonalRulesCannotRequestTheException(string profile)
    {
        var f = await Fixture.Create(); Layout(f, profile);
        var scan = await Scans(f).ScanAsync(f.Workspace.Id, new());
        Assert.Equal("review", Rust(scan).State);
        Assert.Contains("protected_data", scan.Candidates.Single(item => item.RuleId == "dev.rust-target").BlockedReasons);
        var plan = await Service(f, new Tracking()).CreatePlanAsync(scan.Id, [Rust(scan).Id]);
        Assert.Contains(plan.Items[0].Manifest, item => item.Path.Name == "bindings.rs");
        Assert.Contains(plan.Items[0].Context, item => item.Path.Name == "Cargo.toml");
        Assert.Equal(0, f.Mutation.Calls);
    }

    [Theory]
    [InlineData("CACHEDIR.TAG")]
    [InlineData(".rustc_info.json")]
    [InlineData("debug/.fingerprint")]
    public async Task MissingLayoutEvidenceKeepsGeneratedSourceProtected(string missing)
    {
        var f = await Fixture.Create(); Layout(f);
        f.Files.Entries.Remove(f.Workspace.Path.Append("project-0/target/" + missing).Value);
        Assert.Contains("protected_data", Rust(await Scans(f).ScanAsync(f.Workspace.Id, new())).BlockedReasons);
    }

    [Theory]
    [InlineData("main.rs")]
    [InlineData("debug/build/copied/out/main.rs")]
    [InlineData("debug/build/crate-01234567/source/main.rs")]
    [InlineData("debug/build/crate-01234567/out/Cargo.toml")]
    [InlineData("debug/build/crate-01234567/out/package.json")]
    [InlineData("debug/build/crate-01234567/out/private.key")]
    [InlineData("debug/build/crate-01234567/out/.env.local")]
    [InlineData("debug/build/crate-01234567/out/nested/.git/config")]
    public async Task AdjacentSourceManifestsSecretsAndRepositoriesRetainProtection(string relative)
    {
        var f = await Fixture.Create(); Layout(f); Add(f, "project-0/target/" + relative);
        Assert.Contains("protected_data", Rust(await Scans(f).ScanAsync(f.Workspace.Id, new())).BlockedReasons);
    }

    [Fact]
    public async Task SpoofedBuiltinIdWithChangedDefinitionDoesNotGrantTheException()
    {
        var f = await Fixture.Create(); Layout(f);
        var catalog = Catalog(f);
        var rule = catalog.RulesFor(f.Workspace).Single(rule => rule.Id == RuleId);
        var changed = JsonNode.Parse(rule.Definition.GetRawText())!;
        changed["description"] = "untrusted replacement";
        var scan = await Scans(f).PreviewAsync(f.Workspace.Id, Encoding.UTF8.GetBytes(changed.ToJsonString()), new());
        Assert.Contains("protected_data", Rust(scan).BlockedReasons);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("tracked")]
    [InlineData("unavailable")]
    public async Task GitEvidenceIsRequiredEvenForBinaryOnlyBuiltinTargets(string state)
    {
        var f = await Fixture.Create();
        var scan = await Scans(f).ScanAsync(f.Workspace.Id, new());
        var tracking = state == "missing" ? null : new Tracking { Tracked = state == "tracked" };
        if (state == "unavailable") tracking!.Read = _ => throw new ShouException("permission_denied", "generated fixture");
        var error = await Assert.ThrowsAsync<ShouException>(() => Service(f, tracking).CreatePlanAsync(scan.Id, [Rust(scan).Id]));
        Assert.Equal(state == "tracked" ? "tracked_artifact_content" : "artifact_evidence_unavailable", error.Code);
        Assert.Equal(0, f.Mutation.Calls);
        Assert.DoesNotContain(f.Store.Records.Keys, key => key.StartsWith("plan_", StringComparison.Ordinal));
    }

    [Fact]
    public async Task TrackingChangesAfterConfirmationRejectBeforeIntentAndKeepAllBytes()
    {
        var f = await Fixture.Create(); Layout(f);
        var tracking = new Tracking(); var service = Service(f, tracking);
        var scan = await Scans(f).ScanAsync(f.Workspace.Id, new());
        var plan = await service.CreatePlanAsync(scan.Id, [Rust(scan).Id]);
        var consent = await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation());
        tracking.Tracked = true;
        var error = await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan.Id, consent));
        Assert.Equal("tracked_artifact_content", error.Code);
        Assert.Null(await service.ExecutionAsync(plan.Id));
        Assert.True(f.Files.Entries.ContainsKey(f.Workspace.Path.Append("project-0/target/debug/build/bindgen-0123456789abcdef/out/bindings.rs").Value));
        Assert.Equal(0, f.Mutation.Calls);
    }

    [Fact]
    public async Task NativeManifestVerificationDoesNotSkipPerItemGitRechecks()
    {
        var f = await Fixture.Create(2); Layout(f); Layout(f, project: 1);
        var tracking = new Tracking(); var service = Service(f, tracking, new VerifiedMutation(f, tracking));
        var scan = await Scans(f).ScanAsync(f.Workspace.Id, new());
        var plan = await service.CreatePlanAsync(scan.Id, scan.Candidates.Where(item => item.RuleId == RuleId).Select(item => item.Id));
        var result = await service.ExecuteAsync(plan.Id, await service.ConfirmAsync(plan.Id, new CleanupTests.Confirmation()));
        Assert.Equal(CleanupItemState.Purged, result.Items[0].State);
        Assert.Equal(CleanupItemState.Failed, result.Items[1].State);
        Assert.Equal("tracked_artifact_content", result.Items[1].Reason);
        Assert.Equal(6, tracking.Calls); // Two plans, two preflights, and one observation immediately before each item.
        Assert.Equal(1, f.Mutation.Calls);
        Assert.True(f.Files.Entries.ContainsKey(f.Workspace.Path.Append("project-1/target/debug/build/bindgen-0123456789abcdef/out/bindings.rs").Value));
    }

    [Fact]
    public async Task NewAdjacentSourceAfterScanRejectsTheOldSelection()
    {
        var f = await Fixture.Create(); Layout(f);
        var scan = await Scans(f).ScanAsync(f.Workspace.Id, new());
        Add(f, "project-0/target/hand-written.rs");
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => Service(f, new Tracking()).CreatePlanAsync(scan.Id, [Rust(scan).Id]))).Code);
        Assert.Equal(0, f.Mutation.Calls);
    }

    [Fact]
    public async Task TrackingSharesTheActivityDeadlineAndCannotCompleteLateWithPermission()
    {
        var f = await Fixture.Create(); var plan = await f.Plan();
        var item = plan.Items[0] with { RuleId = RuleId };
        var pending = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var tracking = new Tracking { Read = _ => pending.Task };
        var clock = new ManualDeadlineClock();
        var checking = new CleanupActivityService(new Files(), new Processes(), clock, tracking).InspectAsync(f.Workspace, item, default);
        Assert.False(checking.IsCompleted);
        clock.Expire();
        var result = await checking;
        Assert.Equal(ActivityState.Unknown, result.State);
        Assert.Equal("activity_time_limit", result.Reason);
        pending.SetResult(false);
        Assert.Equal(ActivityState.Unknown, result.State);
    }

    [Fact]
    public async Task CallerCancellationDuringTrackingRemainsCancellation()
    {
        var f = await Fixture.Create(); var plan = await f.Plan();
        using var cancelled = new CancellationTokenSource();
        var tracking = new Tracking { Read = async token => { await Task.Delay(Timeout.InfiniteTimeSpan, token); return false; } };
        var checking = new CleanupActivityService(new Files(), new Processes(), tracking: tracking)
            .InspectAsync(f.Workspace, plan.Items[0] with { RuleId = RuleId }, cancelled.Token);
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => checking);
    }
}
