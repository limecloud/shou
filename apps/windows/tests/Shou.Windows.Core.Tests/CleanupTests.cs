using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class CleanupTests
{
    private const string Owner = "S-1-5-21-1000";
    private static readonly WindowsPath Root = WindowsPath.Parse("C:/Users/Dev/Projects");
    internal sealed class TestClock : TimeProvider
    {
        public DateTimeOffset Now = new(2026, 10, 23, 0, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }
    internal sealed class Confirmation(bool approve = true) : ICleanupConfirmation
    {
        public CleanupReview? Review;
        public Func<Task>? BeforeReturn;
        public async Task<bool> RequestAsync(CleanupReview review, CancellationToken cancellationToken)
        {
            Review = review;
            if (BeforeReturn is not null) await BeforeReturn();
            return approve;
        }
    }
    internal sealed class Activity : ICleanupActivity
    {
        public ActivityState State = ActivityState.Idle;
        public Task<ActivityObservation> InspectAsync(Workspace workspace, CleanupPlanItem item, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(new ActivityObservation(State));
        }
    }
    internal sealed class Mutation(MemoryFileSystem files, MemoryRecordStore store) : ICleanupMutation
    {
        public int Calls;
        public bool Available = true;
        public Func<CleanupPlanItem, CleanupAction, CancellationToken, Task<CleanupMutationResult>>? Apply;
        public bool Supports(CleanupAction action) => Available;
        public async Task<CleanupMutationResult> ApplyAsync(Workspace workspace, CleanupPlanItem item, CleanupAction action, CancellationToken cancellationToken)
        {
            Calls++;
            var journal = JsonSerializer.Deserialize<CleanupExecution>(store.Records.Single(pair => pair.Key.StartsWith("execution_", StringComparison.Ordinal)).Value, ContractJson.Options)!;
            Assert.Equal(action == CleanupAction.Permanent ? CleanupItemState.Purging : CleanupItemState.Moving, journal.Items.Single(result => result.ItemId == item.Id).State);
            if (Apply is not null) return await Apply(item, action, cancellationToken);
            if (action == CleanupAction.Trash) return new(CleanupMutationOutcome.Completed, ResultPath: WindowsPath.Parse("C:/$Recycle.Bin/generated/" + item.Id), ResultIdentity: item.Manifest[0].Identity);
            foreach (var entry in item.Manifest) Assert.True(files.Entries.Remove(entry.Path.Value));
            return new(CleanupMutationOutcome.Completed, item.Manifest.Length);
        }
    }
    internal sealed class Fixture
    {
        public readonly MemoryFileSystem Files = new();
        public readonly MemoryRecordStore Store = new();
        public readonly RuleSchemaValidator Validator = new(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Contracts/rule.schema.json")));
        public readonly TestClock Clock = new();
        public readonly Activity Activity = new();
        public readonly CleanupProtectionContext Protection = new(Owner, WindowsPath.Parse("C:/Users/Dev"), WindowsPath.Parse("C:/Users/Dev/AppData/Local/Shou/Data"), [WindowsPath.Parse("C:/Windows")]);
        public Mutation Mutation = null!;
        public Workspace Workspace = null!;
        public CleanupService Service = null!;
        public ConfigurationService Configuration => new(Store, Validator, Files, Owner, Clock);
        public CleanupScanService Scans => new(Store, Validator, new StorageScanner(Files, Clock), Protection, Clock);
        public CleanupService NewService() => new(Store, Validator, new StorageScanner(Files, Clock), Protection, Activity, Mutation, Clock);
        public static async Task<Fixture> Create(int projects = 1)
        {
            var fixture = new Fixture();
            fixture.Files.Add(Root.Value, EntryKind.Directory);
            for (var index = 0; index < projects; index++) fixture.AddProject("project-" + index);
            fixture.Workspace = await fixture.Configuration.AddWorkspaceAsync(Root, "developer-workspaces");
            await fixture.Configuration.ImportRuleAsync(Rule());
            await fixture.Configuration.SetRuleAsync(fixture.Workspace.Id, "dev.rust-target", true);
            fixture.Mutation = new(fixture.Files, fixture.Store);
            fixture.Service = fixture.NewService();
            return fixture;
        }
        public void AddProject(string name)
        {
            Files.Add(Root.Append(name).Value, EntryKind.Directory);
            Files.Add(Root.Append(name + "/Cargo.toml").Value);
            Files.Add(Root.Append(name + "/target").Value, EntryKind.Directory);
            Files.Add(Root.Append(name + "/target/cache.bin").Value);
        }
        public async Task<CleanupPlan> Plan(CleanupAction action = CleanupAction.Permanent)
        {
            var scan = await Scans.ScanAsync(Workspace.Id, new());
            return await Service.CreatePlanAsync(scan.Id, scan.Candidates.Select(candidate => candidate.Id), action);
        }
    }
    internal static byte[] Rule(string id = "dev.rust-target", string version = "1.0.0")
    {
        var node = JsonNode.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Examples/rust-target.rule.json")))!;
        node["platforms"] = new JsonArray("windows");
        node["id"] = id;
        node["version"] = version;
        node["conditions"]!["min_allocated_bytes"] = 0;
        return Encoding.UTF8.GetBytes(node.ToJsonString());
    }

    [Fact]
    public async Task EnabledScanFreezesEveryExplicitBindingWithoutEnablingDrafts()
    {
        var fixture = await Fixture.Create();
        await fixture.Configuration.ImportRuleAsync(Rule("dev.another-cache"));
        var first = await fixture.Scans.ScanAsync(fixture.Workspace.Id, new());
        Assert.False(first.PreviewOnly);
        Assert.Single(first.Rules);
        Assert.Single(first.Candidates);
        await fixture.Configuration.SetRuleAsync(fixture.Workspace.Id, "dev.another-cache", true);
        var second = await fixture.Scans.ScanAsync(fixture.Workspace.Id, new());
        Assert.Equal(2, second.Rules.Length);
        Assert.Equal(2, second.Candidates.Length);
        Assert.Equal(2, (await fixture.Scans.ResultsAsync(second.Id)).CandidateCount);
        await fixture.Configuration.SetRuleAsync(fixture.Workspace.Id, "dev.rust-target", false);
        Assert.Single((await fixture.Scans.ScanAsync(fixture.Workspace.Id, new())).Rules);
    }

    [Fact]
    public async Task DraftPreviewsNeverBecomePlanSourcesEvenForAnEnabledDefinition()
    {
        var fixture = await Fixture.Create();
        var scan = await fixture.Scans.PreviewAsync(fixture.Workspace.Id, Rule(), new());
        Assert.True(scan.PreviewOnly);
        var error = await Assert.ThrowsAsync<ShouException>(() => fixture.Service.CreatePlanAsync(scan.Id, scan.Candidates.Select(candidate => candidate.Id)));
        Assert.Equal("preview_only", error.Code);
        Assert.Equal(0, fixture.Mutation.Calls);
        Assert.DoesNotContain(fixture.Store.Records.Keys, key => key.StartsWith("plan_", StringComparison.Ordinal));
    }

    [Fact]
    public async Task PlansFreezeExactManifestsActionContextAndTenMinuteExpiry()
    {
        var fixture = await Fixture.Create();
        var original = fixture.Files.Entries.ToArray();
        var plan = await fixture.Plan();
        Assert.Equal(CleanupAction.Permanent, plan.Action);
        Assert.Equal(TimeSpan.FromMinutes(10), plan.ExpiresAt - plan.CreatedAt);
        Assert.StartsWith("sha256:", plan.Digest);
        Assert.Equal(2, plan.Items[0].Manifest.Length);
        Assert.Contains(plan.Items[0].Context, entry => entry.Path.Name == "Cargo.toml");
        Assert.Equal(original, fixture.Files.Entries.ToArray());
        Assert.Null(await fixture.Service.ExecutionAsync(plan.Id));
        Assert.Equal(plan.Digest, (await fixture.Service.PlanAsync(plan.Id)).Digest);
    }

    [Fact]
    public async Task OneCurrentConfirmationExecutesOnlyTheFrozenTargetsAndCannotReplay()
    {
        var fixture = await Fixture.Create(2);
        var plan = await fixture.Plan();
        var confirmation = new Confirmation();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, confirmation);
        Assert.Equal(plan.Digest, confirmation.Review!.Digest);
        Assert.Equal(plan.Items.Select(item => item.Path), confirmation.Review.Items.Select(item => item.Path));
        var execution = await fixture.Service.ExecuteAsync(plan.Id, consent);
        Assert.Equal(CleanupExecutionState.Completed, execution.State);
        Assert.All(execution.Items, item => Assert.Equal(CleanupItemState.Purged, item.State));
        Assert.Equal(2, fixture.Mutation.Calls);
        Assert.Equal(5, fixture.Files.Entries.Count);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent))).Code);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ConfirmAsync(plan.Id, new Confirmation()))).Code);
    }

    [Theory]
    [InlineData(ActivityState.Active)]
    [InlineData(ActivityState.Unknown)]
    public async Task ActivityMustBeKnownIdleBeforePlanningAndBeforeExecution(ActivityState state)
    {
        var fixture = await Fixture.Create();
        fixture.Activity.State = state;
        Assert.Equal(state == ActivityState.Active ? "active_target" : "activity_unknown", (await Assert.ThrowsAsync<ShouException>(() => fixture.Plan())).Code);
        fixture.Activity.State = ActivityState.Idle;
        var plan = await fixture.Plan();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, new Confirmation());
        fixture.Activity.State = state;
        var result = await fixture.Service.ExecuteAsync(plan.Id, consent);
        Assert.Equal(CleanupItemState.Failed, Assert.Single(result.Items).State);
        Assert.NotNull(await fixture.Service.ExecutionAsync(plan.Id));
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task ConfirmationIsRequiredDeniedExpiredAndBoundToTheIssuingService()
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, null))).Code);
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ConfirmAsync(plan.Id, new Confirmation(false)))).Code);
        var consent = await fixture.Service.ConfirmAsync(plan.Id, new Confirmation());
        Assert.Equal("{}", JsonSerializer.Serialize(consent, ContractJson.Options));
        Assert.Throws<NotSupportedException>(() => JsonSerializer.Deserialize<CleanupConsent>("{}", ContractJson.Options));
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => fixture.NewService().ExecuteAsync(plan.Id, consent))).Code);
        fixture.Clock.Now += TimeSpan.FromMinutes(2);
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent))).Code);
        fixture.Clock.Now += TimeSpan.FromMinutes(10);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ConfirmAsync(plan.Id, new Confirmation()))).Code);
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Theory]
    [InlineData("configuration")]
    [InlineData("identity")]
    [InlineData("new-child")]
    [InlineData("marker")]
    [InlineData("parent")]
    public async Task ChangedEvidenceAfterConfirmationReportsItemFailure(string change)
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, new Confirmation());
        var file = Root.Append("project-0/target/cache.bin").Value;
        switch (change)
        {
            case "configuration": await fixture.Configuration.SetExclusionAsync(null, "**/cache.bin", false); break;
            case "identity": fixture.Files.Entries[file] = fixture.Files.Entries[file] with { Identity = new(1, 1000.ToString("x32"), Owner) }; break;
            case "new-child": fixture.Files.Add(Root.Append("project-0/target/new.bin").Value); break;
            case "marker":
                var marker = Root.Append("project-0/Cargo.toml").Value;
                fixture.Files.Entries[marker] = fixture.Files.Entries[marker] with { LastWriteUtc = fixture.Clock.Now };
                break;
            case "parent":
                var parent = Root.Append("project-0").Value;
                fixture.Files.Entries[parent] = fixture.Files.Entries[parent] with { Identity = new(1, 1000.ToString("x32"), Owner) };
                break;
        }
        if (change == "configuration")
        {
            Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent))).Code);
            Assert.Null(await fixture.Service.ExecutionAsync(plan.Id));
        }
        else
        {
            var result = await fixture.Service.ExecuteAsync(plan.Id, consent);
            Assert.Equal(CleanupItemState.Failed, Assert.Single(result.Items).State);
            Assert.NotNull(await fixture.Service.ExecutionAsync(plan.Id));
        }
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task PromptDoesNotHoldTheMutationLeaseAndLaterConfigurationChangesInvalidateConsent()
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var confirmation = new Confirmation { BeforeReturn = async () => await fixture.Configuration.SetExclusionAsync(null, "**/keep", false) };
        var consent = await fixture.Service.ConfirmAsync(plan.Id, confirmation);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent))).Code);
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task PartialUnrelatedCoveragePreservesAnIndependentlyCompleteTarget()
    {
        var fixture = await Fixture.Create();
        var other = Root.Append("unavailable");
        fixture.Files.Add(other.Value, EntryKind.Directory);
        fixture.Files.Denied.Add(other.Value);
        var plan = await fixture.Plan();
        var execution = await fixture.Service.ExecuteAsync(plan.Id, await fixture.Service.ConfirmAsync(plan.Id, new Confirmation()));
        Assert.Equal(CleanupExecutionState.Completed, execution.State);
        Assert.True(fixture.Files.Entries.ContainsKey(other.Value));
    }

    [Fact]
    public async Task MultipleRulesCannotSelectTheSameTargetTwice()
    {
        var fixture = await Fixture.Create();
        await fixture.Configuration.ImportRuleAsync(Rule("dev.another-cache"));
        await fixture.Configuration.SetRuleAsync(fixture.Workspace.Id, "dev.another-cache", true);
        var scan = await fixture.Scans.ScanAsync(fixture.Workspace.Id, new());
        Assert.Equal(2, scan.Candidates.Length);
        Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.CreatePlanAsync(scan.Id, scan.Candidates.Select(candidate => candidate.Id)))).Code);
    }

    [Fact]
    public async Task ChangedConfigurationAndProtectedOrIncompleteCandidatesCannotProducePlans()
    {
        var fixture = await Fixture.Create();
        var scan = await fixture.Scans.ScanAsync(fixture.Workspace.Id, new());
        await fixture.Configuration.SetExclusionAsync(null, "**/keep", false);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.CreatePlanAsync(scan.Id, scan.Candidates.Select(candidate => candidate.Id)))).Code);
        fixture.Files.Add(Root.Append("project-0/target/.npmrc").Value);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => fixture.Plan())).Code);
        fixture.Files.Entries.Remove(Root.Append("project-0/target/.npmrc").Value);
        fixture.Files.Denied.Add(Root.Append("project-0/target").Value);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => fixture.Plan())).Code);
    }

    [Theory]
    [InlineData("initial")]
    [InlineData("intent")]
    [InlineData("result")]
    [InlineData("final")]
    public async Task JournalFailuresStopAtTheLastDurableBoundaryWithoutReplaying(string boundary)
    {
        var fixture = await Fixture.Create(2);
        var plan = await fixture.Plan();
        var consent = await fixture.Service.ConfirmAsync(plan.Id, new Confirmation());
        fixture.Store.FailPublication = (key, bytes) =>
        {
            if (!key.StartsWith("execution_", StringComparison.Ordinal)) return false;
            var execution = JsonSerializer.Deserialize<CleanupExecution>(bytes, ContractJson.Options)!;
            return boundary switch
            {
                "initial" => execution.Items.All(item => item.State == CleanupItemState.Pending),
                "intent" => execution.Items[0].State == CleanupItemState.Purging,
                "result" => execution.Items[0].State == CleanupItemState.Purged,
                _ => execution.State == CleanupExecutionState.Completed
            };
        };
        Assert.Equal("journal_write_failed", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ExecuteAsync(plan.Id, consent))).Code);
        Assert.Equal(boundary is "initial" or "intent" ? 0 : boundary == "result" ? 1 : 2, fixture.Mutation.Calls);
        fixture.Store.FailPublication = null;
        var saved = await fixture.Service.ExecutionAsync(plan.Id);
        if (boundary == "initial") Assert.Null(saved);
        else
        {
            Assert.Equal(CleanupExecutionState.Executing, saved!.State);
            if (boundary == "result") Assert.Equal(CleanupItemState.Purging, saved.Items[0].State);
            Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ConfirmAsync(plan.Id, new Confirmation()))).Code);
        }
    }

    [Fact]
    public async Task UnknownNativeOutcomesStopTheBatchAndPreserveUncertainty()
    {
        var fixture = await Fixture.Create(2);
        var plan = await fixture.Plan();
        fixture.Mutation.Apply = (_, _, _) => throw new IOException("Injected native result loss");
        var execution = await fixture.Service.ExecuteAsync(plan.Id, await fixture.Service.ConfirmAsync(plan.Id, new Confirmation()));
        Assert.Equal(CleanupExecutionState.Unknown, execution.State);
        Assert.Equal(CleanupItemState.Unknown, execution.Items[0].State);
        Assert.Equal(CleanupItemState.Skipped, execution.Items[1].State);
        Assert.Equal(1, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task KnownPartialRemovalIsNotReportedAsPurgedAndOtherTargetsRemainIndependent()
    {
        var fixture = await Fixture.Create(2);
        var plan = await fixture.Plan();
        fixture.Mutation.Apply = (item, _, _) =>
        {
            if (item.Id == plan.Items[0].Id)
            {
                fixture.Files.Entries.Remove(item.Manifest[1].Path.Value);
                return Task.FromResult(new CleanupMutationResult(CleanupMutationOutcome.Failed, 1, "purge_incomplete"));
            }
            foreach (var entry in item.Manifest) fixture.Files.Entries.Remove(entry.Path.Value);
            return Task.FromResult(new CleanupMutationResult(CleanupMutationOutcome.Completed, item.Manifest.Length));
        };
        var execution = await fixture.Service.ExecuteAsync(plan.Id, await fixture.Service.ConfirmAsync(plan.Id, new Confirmation()));
        Assert.Equal(CleanupExecutionState.Partial, execution.State);
        Assert.Equal(CleanupItemState.Failed, execution.Items[0].State);
        Assert.Equal(1, execution.Items[0].RemovedEntries);
        Assert.Equal(CleanupItemState.Purged, execution.Items[1].State);
    }

    [Fact]
    public async Task CancellationAfterOneNativeItemRecordsItsResultAndStopsNewWork()
    {
        var fixture = await Fixture.Create(2);
        var plan = await fixture.Plan();
        using var cancelled = new CancellationTokenSource();
        fixture.Mutation.Apply = (item, _, _) =>
        {
            foreach (var entry in item.Manifest) fixture.Files.Entries.Remove(entry.Path.Value);
            cancelled.Cancel();
            return Task.FromResult(new CleanupMutationResult(CleanupMutationOutcome.Completed, item.Manifest.Length));
        };
        var execution = await fixture.Service.ExecuteAsync(plan.Id, await fixture.Service.ConfirmAsync(plan.Id, new Confirmation()), cancellationToken: cancelled.Token);
        Assert.Equal(CleanupExecutionState.Cancelled, execution.State);
        Assert.Equal(CleanupItemState.Purged, execution.Items[0].State);
        Assert.Equal(CleanupItemState.Cancelled, execution.Items[1].State);
        Assert.Equal(1, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task TrashIntentCompletesTheCurrentNativeItemAndRequiresAnObservedDestination()
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan(CleanupAction.Trash);
        using var cancelled = new CancellationTokenSource();
        fixture.Mutation.Apply = (item, action, token) =>
        {
            Assert.False(token.CanBeCanceled);
            cancelled.Cancel();
            return Task.FromResult(new CleanupMutationResult(CleanupMutationOutcome.Completed));
        };
        var execution = await fixture.Service.ExecuteAsync(plan.Id, await fixture.Service.ConfirmAsync(plan.Id, new Confirmation()), cancellationToken: cancelled.Token);
        Assert.Equal(CleanupExecutionState.Unknown, execution.State);
        Assert.Null(execution.Items[0].ResultPath);
        fixture = await Fixture.Create();
        plan = await fixture.Plan(CleanupAction.Trash);
        execution = await fixture.Service.ExecuteAsync(plan.Id, await fixture.Service.ConfirmAsync(plan.Id, new Confirmation()));
        Assert.Equal(CleanupItemState.Trashed, execution.Items[0].State);
        Assert.NotNull(execution.Items[0].ResultPath);
        Assert.Equal(0, execution.Items[0].RemovedEntries);
    }

    [Fact]
    public async Task CompetingConfigurationWritesFailWhileExecutionKeepsTheLease()
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        fixture.Mutation.Apply = async (item, _, _) =>
        {
            Assert.Equal("store_busy", (await Assert.ThrowsAsync<ShouException>(() => fixture.Configuration.SetExclusionAsync(null, "**/keep", false))).Code);
            foreach (var entry in item.Manifest) fixture.Files.Entries.Remove(entry.Path.Value);
            return new(CleanupMutationOutcome.Completed, item.Manifest.Length);
        };
        Assert.Equal(CleanupExecutionState.Completed, (await fixture.Service.ExecuteAsync(plan.Id, await fixture.Service.ConfirmAsync(plan.Id, new Confirmation()))).State);
    }

    [Theory]
    [InlineData("approved")]
    [InlineData("digest")]
    [InlineData("action")]
    [InlineData("manifest")]
    public async Task TamperedPlansAreRejectedWithoutAnyMutation(string field)
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var node = JsonNode.Parse(fixture.Store.Records[plan.Id])!;
        switch (field)
        {
            case "approved": node["approved"] = true; break;
            case "digest": node["digest"] = "sha256:" + new string('0', 64); break;
            case "action": node["action"] = "trash"; break;
            case "manifest": node["items"]![0]!["manifest"]![1]!["path"] = "C:/Outside/private.bin"; break;
        }
        fixture.Store.Records[plan.Id] = Encoding.UTF8.GetBytes(node.ToJsonString());
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => fixture.Service.ConfirmAsync(plan.Id, new Confirmation()))).Code);
        Assert.Equal(0, fixture.Mutation.Calls);
    }

    [Fact]
    public async Task UnsupportedActionsAndFailedPlanPublicationDoNotChangeTargets()
    {
        var fixture = await Fixture.Create();
        fixture.Mutation.Available = false;
        Assert.Equal("unsupported_capability", (await Assert.ThrowsAsync<ShouException>(() => fixture.Plan(CleanupAction.Trash)) ).Code);
        fixture.Mutation.Available = true;
        fixture.Store.FailPublication = (key, _) => key.StartsWith("plan_", StringComparison.Ordinal);
        Assert.Equal("io_error", (await Assert.ThrowsAsync<ShouException>(() => fixture.Plan())).Code);
        Assert.Equal(0, fixture.Mutation.Calls);
        Assert.Equal(5, fixture.Files.Entries.Count);
    }
}
