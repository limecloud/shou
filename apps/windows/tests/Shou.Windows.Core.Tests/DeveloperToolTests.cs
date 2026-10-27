using System.Text;
using System.Text.Json.Nodes;

namespace Shou.Windows.Core.Tests;

public sealed class DeveloperToolTests
{
    private static DeveloperToolCatalog Catalog() => DeveloperToolCatalog.Decode(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Catalog", "developer-tools.json")));
    private static DeveloperToolPackage Package(DeveloperToolCatalog catalog) => catalog.Tools.Single(t => t.Id == "codex").Packages.Single(p => p.Provider == "winget");
    private sealed class Platform : IDeveloperTools
    {
        internal string? Version;
        internal string Identity = "generated-identity";
        internal int Dispatches;
        internal bool NoChange;
        internal DeveloperToolInspection State(DeveloperToolPackage package) => new(package, Version, "1.0", ManagedPackageUpdateService.OfficialCatalogId, Identity, ManagedPackageScope.User, null);
        public Task<DeveloperToolInspection> InspectAsync(DeveloperToolPackage package, CancellationToken cancellationToken) => Task.FromResult(State(package));
        public Task<ManagedPackageMutationResult> PerformAsync(DeveloperToolAction action, DeveloperToolInspection expected, DateTimeOffset expiresAt, CancellationToken cancellationToken)
        {
            Dispatches++;
            if (!NoChange) Version = action == DeveloperToolAction.Install ? "1.0" : null;
            return Task.FromResult(new ManagedPackageMutationResult(true, true, false, null));
        }
    }
    private sealed class Clock : TimeProvider
    {
        internal DateTimeOffset Now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => Now;
    }
    [Fact]
    public void CatalogCoversAllReferenceCategoriesAndSeparatesAiTools()
    {
        var catalog = Catalog();
        Assert.Equal(17, catalog.Categories.Length); Assert.True(catalog.Tools.Length >= 73);
        Assert.True(catalog.Tools.Single(t => t.Id == "claude-code").IsAI);
        Assert.False(catalog.Tools.Single(t => t.Id == "nginx").IsAI);
        Assert.False(new DeveloperToolPackage("homebrew", "formula", "--all").Valid);
        Assert.False(new DeveloperToolPackage("winget", "package", "Other.Package --force").Valid);
    }
    [Theory]
    [InlineData("homepage", "javascript:alert(1)")]
    [InlineData("category", "unregistered")]
    [InlineData("id", "../outside")]
    public void CatalogRejectsUntrustedAndUnknownDefinitions(string field, string value)
    {
        var source = JsonNode.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Catalog", "developer-tools.json")))!;
        source["tools"]![0]![field] = value;
        Assert.Throws<ShouException>(() => DeveloperToolCatalog.Decode(Encoding.UTF8.GetBytes(source.ToJsonString())));
    }
    [Fact]
    public async Task PlansRequireExactConfirmationJournalIntentAndCannotReplay()
    {
        var catalog = Catalog(); var platform = new Platform(); var store = new MemoryRecordStore();
        var service = new DeveloperToolService(catalog, platform, () => store);
        var package = Package(catalog);
        foreach (var action in new[] { DeveloperToolAction.Install, DeveloperToolAction.Uninstall })
        {
            var inspected = await service.InspectAsync("codex", package);
            var plan = await service.PrepareAsync("codex", action, inspected);
            var result = await service.ExecuteAsync(plan, plan.Id);
            Assert.Equal("succeeded", result.State);
            Assert.Contains("developer_tool_intent_" + plan.Id, store.Records.Keys);
            Assert.Contains("developer_tool_result_" + plan.Id, store.Records.Keys);
            await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan, plan.Id));
        }
        Assert.Equal(2, platform.Dispatches);
    }
    [Theory]
    [InlineData("identity")]
    [InlineData("version")]
    [InlineData("expiry")]
    [InlineData("confirmation")]
    [InlineData("journal")]
    public async Task ChangedAuthorityExpiryAndJournalFailurePreventDispatch(string change)
    {
        var catalog = Catalog(); var platform = new Platform(); var store = new MemoryRecordStore(); var clock = new Clock();
        var service = new DeveloperToolService(catalog, platform, () => store, clock);
        var inspected = await service.InspectAsync("codex", Package(catalog));
        var plan = await service.PrepareAsync("codex", DeveloperToolAction.Install, inspected);
        switch (change)
        {
            case "identity": platform.Identity = "replacement"; break;
            case "version": platform.Version = "another-version"; break;
            case "expiry": clock.Now += TimeSpan.FromMinutes(3); break;
            case "journal": store.FailWrite = true; break;
        }
        await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan, change == "confirmation" ? "wrong" : plan.Id));
        Assert.Equal(0, platform.Dispatches);
    }
    [Fact]
    public async Task ManagerCompletionDoesNotProveRequestedVersionIsInstalled()
    {
        var catalog = Catalog(); var platform = new Platform { NoChange = true }; var store = new MemoryRecordStore();
        var service = new DeveloperToolService(catalog, platform, () => store);
        var inspection = await service.InspectAsync("codex", Package(catalog));
        var plan = await service.PrepareAsync("codex", DeveloperToolAction.Install, inspection);
        Assert.Equal("unknown", (await service.ExecuteAsync(plan, plan.Id)).State);
    }
    [Fact]
    public async Task DiscoveryDoesNotGrantAuthorityToAnotherToolOrSource()
    {
        var catalog = Catalog(); var platform = new Platform(); var store = new MemoryRecordStore();
        var service = new DeveloperToolService(catalog, platform, () => store);
        await Assert.ThrowsAsync<ShouException>(() => service.InspectAsync("nginx", Package(catalog)));
        await Assert.ThrowsAsync<ShouException>(() => service.InspectAsync("codex", new("winget", "package", "Other.Package")));
        Assert.Empty(store.Records); Assert.Equal(0, platform.Dispatches);
    }
}
