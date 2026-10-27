using System.Collections.Immutable;
namespace Shou.Windows.Core.Tests;

public sealed class DeveloperServiceTests
{
    private static DeveloperToolCatalog Catalog() => DeveloperToolCatalog.Decode(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Catalog", "developer-tools.json")));
    private static readonly DeveloperToolInventory Empty = new([], DateTimeOffset.UtcNow, []);
    private sealed class Stages : IProgress<DeveloperServiceProgress>
    {
        internal readonly List<string> Values = [];
        public void Report(DeveloperServiceProgress value) => Values.Add(value.Stage);
    }
    private sealed class Platform : IDeveloperServices
    {
        internal bool Running, NoChange, FailStop, FailStart;
        internal List<bool> Transitions = [];
        internal string Definition = "generated-definition";
        internal int Dispatches;
        internal List<string[]> RequestedTools = [];
        internal bool IgnoresScope;
        internal DeveloperService Row => new("generated-service", "nginx", "WinGet", "ShouFixture_service", "1.0", @"C:\generated\tool", @"C:\generated\tool\service.exe", Running ? "running" : "stopped", false, Definition + Running, Definition, null);
        public Task<DeveloperServiceSnapshot> ScanAsync(DeveloperToolCatalog catalog, DeveloperToolInventory inventory, CancellationToken token)
        {
            RequestedTools.Add(catalog.Tools.Select(t => t.Id).ToArray());
            return Task.FromResult(new DeveloperServiceSnapshot(IgnoresScope || catalog.Tools.Any(t => t.Id == Row.ToolId) ? [Row] : [], []));
        }
        public Task<DeveloperService> InspectAsync(DeveloperService expected, CancellationToken token) => Task.FromResult(Row);
        public Task SetRunningAsync(bool running, DeveloperService expected, DateTimeOffset expiresAt, CancellationToken token) { Dispatches++; Transitions.Add(running); if (running && FailStart || !running && FailStop) throw new ShouException("fixture_failure", "Generated transition failure."); if (!NoChange) Running = running; return Task.CompletedTask; }
    }
    [Fact]
    public async Task SelectedToolLoadsAreScopedAndPreserveOtherObservations()
    {
        var platform = new Platform(); var controller = new DeveloperServiceController(Catalog(), platform, () => new MemoryRecordStore());
        var nginx = (await controller.ScanAsync(Empty, toolId: "nginx")).Services[0];
        Assert.Empty((await controller.ScanAsync(Empty, toolId: "mysql")).Services);
        Assert.Equal(new[] { "nginx" }, platform.RequestedTools[0]); Assert.Equal(new[] { "mysql" }, platform.RequestedTools[1]);
        Assert.Equal("succeeded", (await controller.SetRunningAsync(true, nginx)).State);
        var refreshed = (await controller.ScanAsync(Empty, toolId: "nginx")).Services[0];
        Assert.Empty((await controller.ScanAsync(Empty, toolIds: new HashSet<string>(["mysql", "redis"], StringComparer.Ordinal))).Services);
        Assert.Equal(new[] { "mysql", "redis" }, platform.RequestedTools[^1].Order(StringComparer.Ordinal));
        await Assert.ThrowsAsync<ShouException>(() => controller.ScanAsync(Empty, toolId: "nginx", toolIds: new HashSet<string>(["mysql"])));
        platform.IgnoresScope = true;
        await Assert.ThrowsAsync<ShouException>(() => controller.ScanAsync(Empty, toolId: "mysql"));
        await Assert.ThrowsAsync<ShouException>(() => controller.ScanAsync(Empty, toolId: "unknown-tool"));
        Assert.Equal("succeeded", (await controller.SetRunningAsync(false, refreshed)).State);
        Assert.Equal(2, platform.Dispatches);
    }
    [Theory]
    [InlineData("none")]
    [InlineData("stop")]
    [InlineData("unchanged")]
    [InlineData("start")]
    public async Task RestartRequiresVerifiedStopAndPreservesPartialResults(string failure)
    {
        var platform = new Platform { Running = true, NoChange = failure == "unchanged", FailStop = failure == "stop", FailStart = failure == "start" };
        var store = new MemoryRecordStore(); var controller = new DeveloperServiceController(Catalog(), platform, () => store);
        var row = (await controller.ScanAsync(Empty)).Services[0];
        var stages = new Stages();
        var result = await controller.PerformAsync(DeveloperServiceAction.Restart, row, progress: stages);
        Assert.Equal(DeveloperServiceAction.Restart, result.Action);
        Assert.Equal(failure is "none" or "start" ? [false, true] : new[] { false }, platform.Transitions);
        Assert.Equal(failure == "none" ? "succeeded" : failure == "start" ? "partial" : "unknown", result.State);
        Assert.Equal(failure is "none" ? ["stopping", "stopped", "starting", "verifying"] : failure is "start" ? ["stopping", "stopped", "starting"] : new[] { "stopping" }, stages.Values);
        Assert.Equal(failure == "none" ? null : failure == "unchanged" ? "developer_service_changed" : "fixture_failure", result.FailureCode);
        if (failure != "none") Assert.Equal(failure == "start" ? "starting" : "stopping", result.Stage);
        if (failure is "none" or "start") Assert.Contains("developer_service_stage_" + result.Id, store.Records.Keys);
        if (failure != "none") await Assert.ThrowsAsync<ShouException>(() => controller.PerformAsync(DeveloperServiceAction.Restart, row));
    }
    [Fact]
    public async Task ExactSwitchesAreSingleUseAndJournalVerifiedOutcomes()
    {
        var platform = new Platform(); var store = new MemoryRecordStore(); var controller = new DeveloperServiceController(Catalog(), platform, () => store);
        foreach (var running in new[] { true, false })
        {
            var row = (await controller.ScanAsync(Empty)).Services[0];
            var result = await controller.SetRunningAsync(running, row);
            Assert.Equal("succeeded", result.State); Assert.False(result.Observed!.RegisteredAtLogin);
            Assert.Contains("developer_service_intent_" + result.Id, store.Records.Keys);
            Assert.Contains("developer_service_result_" + result.Id, store.Records.Keys);
            await Assert.ThrowsAsync<ShouException>(() => controller.SetRunningAsync(running, row));
        }
        Assert.Equal(2, platform.Dispatches);
    }
    [Theory]
    [InlineData("definition")]
    [InlineData("source")]
    [InlineData("journal")]
    public async Task ChangedSourceOrMissingJournalPreventsDispatch(string change)
    {
        var platform = new Platform(); var store = new MemoryRecordStore(); var controller = new DeveloperServiceController(Catalog(), platform, () => store);
        var row = (await controller.ScanAsync(Empty)).Services[0];
        if (change == "definition") platform.Definition = "replacement";
        if (change == "source") row = row with { Source = "Other Manager" };
        if (change == "journal") store.FailWrite = true;
        await Assert.ThrowsAsync<ShouException>(() => controller.SetRunningAsync(true, row)); Assert.Equal(0, platform.Dispatches);
    }
    [Fact]
    public async Task UnknownResultCannotReissueTheObservedRequest()
    {
        var platform = new Platform { NoChange = true }; var store = new MemoryRecordStore(); var controller = new DeveloperServiceController(Catalog(), platform, () => store);
        var row = (await controller.ScanAsync(Empty)).Services[0];
        Assert.Equal("unknown", (await controller.SetRunningAsync(true, row)).State);
        await Assert.ThrowsAsync<ShouException>(() => controller.SetRunningAsync(true, row)); Assert.Equal(1, platform.Dispatches);
    }
}
