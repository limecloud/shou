using System.Collections.Immutable;
using System.Text.Json;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class StartupInventoryTests
{
    private static StartupRegistration Item(string key = "fixture", StartupSource source = StartupSource.CurrentUserRun) => new(source, key, "示例 🧹", @"C:\Example\app.exe");
    private static StartupInventory Inventory(params StartupRegistration[] items) => new(items.ToImmutableArray(), Enum.GetValues<StartupSource>()
        .Select(source => new StartupSourceCoverage(source, StartupSourceState.Complete, items.Count(item => item.Source == source), [])).ToImmutableArray());
    private sealed class Reader(StartupInventory value) : IStartupInventory
    {
        public int Calls { get; private set; }
        public Task<StartupInventory> ReadAsync(StartupDiscoveryBudget budget, CancellationToken cancellationToken)
        { Calls++; return Task.FromResult(value); }
    }
    private static Task<StartupSnapshot> Read(params StartupRegistration[] items) => new StartupInventoryService(new Reader(Inventory(items))).ReadAsync();

    [Fact]
    public async Task RegistrationDoesNotInventEnablementActivityOrMutationAuthorization()
    {
        var result = await Read(Item());
        var item = Assert.Single(result.Items);
        Assert.Equal(ScanState.Complete, result.State);
        Assert.Equal("unknown", item.Enablement);
        Assert.Equal("not_observed", item.RunningState);
        Assert.Null(item.IsOrphan);
        Assert.False(item.ControlAvailable);
        Assert.Contains("scheduled_boot_logon_tasks_visible_to_current_user_only", result.Limitations);
        Assert.Contains("packaged_startup_declarations_only", result.Limitations);
        var json = JsonSerializer.Serialize(result, ContractJson.Options);
        Assert.DoesNotContain("arguments", json);
        Assert.DoesNotContain("environment", json);
        Assert.DoesNotContain("command_line", json);
    }

    [Fact]
    public async Task RegistryIdentityIsCaseInsensitiveAndDifferentSourcesRemainSeparate()
    {
        var first = await Read(Item("Example"), Item("Example", StartupSource.CurrentUserRunOnce));
        var second = await Read(Item("EXAMPLE"), Item("Example", StartupSource.CurrentUserRunOnce));
        Assert.Equal(first.Items.Select(item => item.Id), second.Items.Select(item => item.Id));
        Assert.Equal(2, first.Items.Select(item => item.Id).Distinct().Count());
        Assert.NotEqual(first.Id, second.Id);
    }

    [Fact]
    public async Task DuplicateRegistryNamesCannotCreateTwoIndependentItems()
    {
        var result = await Read(Item("Example"), Item("EXAMPLE"));
        Assert.Single(result.Items);
        Assert.Equal(ScanState.Partial, result.State);
        Assert.Contains("duplicate_registration", result.Sources[0].Issues);
    }

    [Fact]
    public async Task ScheduledTaskIdentityIsCaseInsensitiveAndCanBeFilteredWithoutPathAuthority()
    {
        var first = await Read(Item(@"\Folder\Task", StartupSource.ScheduledTasks) with { ExecutablePath = null });
        var second = await Read(Item(@"\FOLDER\TASK", StartupSource.ScheduledTasks) with { ExecutablePath = null });
        Assert.Equal(first.Items[0].Id, second.Items[0].Id);
        var item = Assert.Single(StartupInventoryService.Page(first, new(Source: StartupSource.ScheduledTasks)).Items);
        Assert.Null(item.DefinitionPath);
        Assert.False(item.ControlAvailable);
        Assert.Equal("unknown", item.Enablement);
        Assert.Contains("scheduled_task_snapshot_not_atomic", first.Limitations);
    }

    [Theory]
    [InlineData(false, ScheduledTaskState.Disabled)]
    [InlineData(true, ScheduledTaskState.Ready)]
    [InlineData(true, ScheduledTaskState.Running)]
    public async Task SchedulerStatusDoesNotBecomeEffectiveStartupEnablementApplicationActivityOrControl(bool enabled, ScheduledTaskState state)
    {
        var snapshot = await Read(Item(@"\Folder\Task", StartupSource.ScheduledTasks) with { ScheduledTask = new(enabled, state) });
        var item = Assert.Single(StartupInventoryService.Page(snapshot, new(Source: StartupSource.ScheduledTasks)).Items);
        Assert.Equal(new ScheduledTaskStatus(enabled, state), item.ScheduledTask);
        Assert.Equal("unknown", item.Enablement);
        Assert.Equal("not_observed", item.RunningState);
        Assert.False(item.ControlAvailable);
        Assert.Null(item.IsOrphan);
        Assert.Contains("scheduled_task_state_is_not_startup_activation_or_process_state", snapshot.Limitations);
        using var json = JsonDocument.Parse(JsonSerializer.Serialize(item, ContractJson.Options));
        Assert.Equal(enabled, json.RootElement.GetProperty("scheduled_task").GetProperty("enabled").GetBoolean());
        Assert.Equal(state.ToString().ToLowerInvariant(), json.RootElement.GetProperty("scheduled_task").GetProperty("state").GetString());
    }

    [Theory]
    [InlineData(StartupSource.CurrentUserRun)]
    [InlineData(StartupSource.PackagedStartupTasks)]
    public async Task OtherSourcesCannotClaimTaskSchedulerObservation(StartupSource source)
    {
        var result = await Read(Item(source: source) with { ScheduledTask = new(true, ScheduledTaskState.Ready) });
        Assert.Empty(result.Items);
        Assert.Equal(ScanState.Partial, result.State);
        Assert.Contains("invalid_registration_metadata", result.Sources.Single(value => value.Source == source).Issues);
    }

    [Fact]
    public async Task InvalidSchedulerStatusesCannotPassTheCoreBoundary()
    {
        var result = await Read(Item(source: StartupSource.ScheduledTasks) with { ScheduledTask = new(true, (ScheduledTaskState)123) });
        Assert.Empty(result.Items);
        Assert.Equal(ScanState.Partial, result.State);
    }

    [Fact]
    public async Task PackagedTaskKeysPreserveExactCaseAndDeclarationsNeverBecomeEnablement()
    {
        var first = await Read(Item("Package!App!task", StartupSource.PackagedStartupTasks));
        var second = await Read(Item("Package!App!TASK", StartupSource.PackagedStartupTasks));
        Assert.NotEqual(first.Items[0].Id, second.Items[0].Id);
        var item = Assert.Single(StartupInventoryService.Page(first, new(Source: StartupSource.PackagedStartupTasks)).Items);
        Assert.Equal("unknown", item.Enablement);
        Assert.False(item.ControlAvailable);
        Assert.Contains("packaged_startup_activation_not_observed", first.Limitations);
    }

    [Theory]
    [InlineData("\u001b[31m")]
    [InlineData("bad\u202evalue")]
    [InlineData("   ")]
    public async Task UntrustedNamesAreDroppedWithAnExplicitCoverageGap(string name)
    {
        var result = await Read(Item() with { Name = name });
        Assert.Empty(result.Items);
        Assert.Equal(ScanState.Partial, result.State);
        Assert.Contains("invalid_registration_metadata", result.Sources[0].Issues);
    }
    [Fact]
    public Task UnpairedSurrogatesCannotReachJson() => UntrustedNamesAreDroppedWithAnExplicitCoverageGap("bad" + (char)0xd800);

    [Theory]
    [InlineData("%LOCALAPPDATA%\\Example.exe")]
    [InlineData("C:\\%USERNAME%\\Example.exe")]
    [InlineData("C:relative.exe")]
    [InlineData("//server/share/app.exe")]
    [InlineData("C:/Example/../app.exe")]
    [InlineData("C:/Example/\u202eapp.exe")]
    public async Task AmbiguousOrUnresolvedPathsRemainUnknownWithoutAnOrphanInference(string path)
    {
        var item = Assert.Single((await Read(Item() with { ExecutablePath = path })).Items);
        Assert.Null(item.ExecutablePath);
        Assert.Null(item.IsOrphan);
        Assert.Contains("unresolved_path", item.Issues);
    }

    [Fact]
    public async Task MissingSourceAndUnreadSourceRemainDistinct()
    {
        var raw = Inventory(Item());
        raw = raw with { Sources = raw.Sources.SetItem(1, new(StartupSource.CurrentUserRunOnce, StartupSourceState.Missing, 0, []))
            .SetItem(2, new(StartupSource.MachineRun64, StartupSourceState.Unavailable, null, ["permission_denied"])) };
        var result = await new StartupInventoryService(new Reader(raw)).ReadAsync();
        Assert.Single(result.Items);
        Assert.Equal(StartupSourceState.Missing, result.Sources[1].State);
        Assert.Null(result.Sources[2].InspectedEntries);
        Assert.Equal(ScanState.Partial, result.State);
    }

    [Fact]
    public async Task KnownAbsentSourcesDoNotMakeAnOtherwiseCompleteFixedSourceScanPartial()
    {
        var raw = Inventory() with { Sources = Enum.GetValues<StartupSource>().Select(source => new StartupSourceCoverage(source, StartupSourceState.Missing, 0, [])).ToImmutableArray() };
        var result = await new StartupInventoryService(new Reader(raw)).ReadAsync();
        Assert.Equal(ScanState.Complete, result.State);
        Assert.Empty(result.Items);
        Assert.Contains("fixed_registration_sources_only", result.Limitations);
    }

    [Fact]
    public async Task PaginationAndFilteringDoNotRereadNativeSources()
    {
        var reader = new Reader(Inventory(Item("Zulu") with { Name = "Zulu" }, Item("Alpha") with { Name = "Alpha" }, Item("Beta", StartupSource.MachineRun64) with { Name = "Beta" }));
        var snapshot = await new StartupInventoryService(reader).ReadAsync();
        var first = StartupInventoryService.Page(snapshot, new(Limit: 2));
        Assert.Equal(new[] { "Alpha", "Beta" }, first.Items.Select(item => item.RegistrationKey));
        Assert.True(first.HasNext);
        var source = StartupInventoryService.Page(snapshot, new(Source: StartupSource.MachineRun64));
        Assert.Equal("Beta", Assert.Single(source.Items).RegistrationKey);
        var search = StartupInventoryService.Page(snapshot, new("app.exe"));
        Assert.Equal(3, search.Total);
        Assert.Equal(snapshot.Id, search.SnapshotId);
        Assert.Equal(1, reader.Calls);
    }

    [Theory]
    [InlineData(0, 5)]
    [InlineData(10001, 5)]
    [InlineData(1, 0)]
    [InlineData(1, 61)]
    public async Task InvalidBudgetsAreRejectedBeforeNativeEnumeration(int entries, int seconds)
    {
        var reader = new Reader(Inventory());
        await Assert.ThrowsAsync<ShouException>(() => new StartupInventoryService(reader).ReadAsync(new(entries, TimeSpan.FromSeconds(seconds))));
        Assert.Equal(0, reader.Calls);
    }

    [Fact]
    public async Task PreCancellationDoesNotReadRegistrations()
    {
        var reader = new Reader(Inventory());
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new StartupInventoryService(reader).ReadAsync(cancellationToken: cancelled.Token));
        Assert.Equal(0, reader.Calls);
    }

    [Fact]
    public async Task MalformedCoverageCannotInventACompleteScan()
    {
        var complete = Inventory(Item());
        var invalid = new[]
        {
            complete with { Sources = complete.Sources.RemoveAt(0) },
            complete with { Sources = complete.Sources.SetItem(1, complete.Sources[0]) },
            complete with { Sources = complete.Sources.SetItem(0, complete.Sources[0] with { InspectedEntries = null }) },
            complete with { Sources = complete.Sources.SetItem(0, complete.Sources[0] with { InspectedEntries = 0 }) },
            complete with { Sources = complete.Sources.SetItem(0, complete.Sources[0] with { State = StartupSourceState.Missing }) },
            complete with { Sources = complete.Sources.SetItem(0, complete.Sources[0] with { Issues = ["private detail"] }) },
            complete with { Registrations = [Item() with { Source = (StartupSource)123 }] }
        };
        foreach (var value in invalid)
            Assert.Equal("startup_inventory_invalid", (await Assert.ThrowsAsync<ShouException>(() => new StartupInventoryService(new Reader(value)).ReadAsync())).Code);
    }
}
