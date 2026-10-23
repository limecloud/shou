using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class ConfigurationTests
{
    private const string Owner = "S-1-5-21-1000";
    private readonly MemoryFileSystem fs = new();
    private readonly MemoryRecordStore store = new();
    private readonly RuleSchemaValidator validator = new(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Contracts/rule.schema.json")));
    private ConfigurationService Service => new(store, validator, fs, Owner);
    private Workspace? workspace;

    private async Task<Workspace> AddRoot()
    {
        if (workspace is not null) return workspace;
        fs.Add("C:/Users/开发者/Projects", EntryKind.Directory);
        return workspace = await Service.AddWorkspaceAsync(WindowsPath.Parse("C:/Users/开发者/Projects"), "developer-workspaces");
    }

    private static byte[] Rule(string version = "1.0.0", bool windows = true, long minimum = 0, string? id = null, string rootRef = "developer-workspaces")
    {
        var node = JsonNode.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Examples/rust-target.rule.json")))!;
        node["platforms"] = new JsonArray(windows ? "windows" : "macos");
        node["version"] = version;
        if (id is not null) node["id"] = id;
        node["conditions"]!["min_allocated_bytes"] = minimum;
        node["scope"]!["root_ref"] = rootRef;
        return Encoding.UTF8.GetBytes(node.ToJsonString());
    }

    [Fact]
    public async Task RegistrationAndReloadKeepNativeIdentityWithoutFilesystemChanges()
    {
        Assert.Equal(Configuration.Empty, await Service.ReadAsync());
        Assert.Empty(store.Records);
        var root = await AddRoot();
        var loaded = await Service.WorkspaceAsync(root.Id);
        Assert.Equal(root.Identity, loaded.Identity);
        Assert.Equal(root.Path, loaded.Path);
        Assert.True(await Service.IsAccessibleAsync(loaded));
        Assert.Single(fs.Entries);
        Assert.Single((await Service.ReadAsync()).Workspaces);
        Assert.Equal(TimeSpan.Zero, root.AddedAt.Offset);
        Assert.NotEqual(Configuration.Empty.Revision, (await Service.ReadAsync()).Revision);
    }

    [Fact]
    public async Task RejectsDuplicateReferencesPhysicalRootsAndForeignOwners()
    {
        var root = await AddRoot();
        var service = Service;
        await Assert.ThrowsAsync<ShouException>(() => service.AddWorkspaceAsync(root.Path, "other"));
        fs.Add("C:/Other", EntryKind.Directory);
        await Assert.ThrowsAsync<ShouException>(() => service.AddWorkspaceAsync(WindowsPath.Parse("C:/Other"), root.RootRef));
        fs.Add("C:/Alias", EntryKind.Directory, identity: root.Identity);
        await Assert.ThrowsAsync<ShouException>(() => service.AddWorkspaceAsync(WindowsPath.Parse("C:/Alias"), "alias"));
        fs.Add("C:/Foreign", EntryKind.Directory, identity: new(1, 1234.ToString("x32"), "S-1-5-21-2000"));
        var error = await Assert.ThrowsAsync<ShouException>(() => service.AddWorkspaceAsync(WindowsPath.Parse("C:/Foreign"), "foreign"));
        Assert.Equal("permission_denied", error.Code);
        Assert.Single((await service.ReadAsync()).Workspaces);
    }

    [Fact]
    public async Task ReplacedWorkspaceIsUnavailableAndIsNotSilentlyRebound()
    {
        var root = await AddRoot();
        fs.Entries[root.Path.Value] = fs.Entries[root.Path.Value] with { Identity = new(1, 1234.ToString("x32"), Owner) };
        Assert.False(await Service.IsAccessibleAsync(root));
        Assert.Equal(root.Identity, (await Service.WorkspaceAsync(root.Id)).Identity);
    }

    [Fact]
    public async Task ImportNeverEnablesAndVersionsCannotOverwriteExistingContent()
    {
        var root = await AddRoot();
        var imported = await Service.ImportRuleAsync(Rule());
        var before = await Service.ReadAsync();
        Assert.Empty(before.Bindings);
        Assert.Equal(imported.Digest, (await Service.ImportRuleAsync(Rule())).Digest);
        Assert.Equal(before.Revision, (await Service.ReadAsync()).Revision);
        var error = await Assert.ThrowsAsync<ShouException>(() => Service.ImportRuleAsync(Rule(minimum: 4)));
        Assert.Equal("version_conflict", error.Code);
        await Service.SetRuleAsync(root.Id, "dev.rust-target", true, "1.0.0");
        await Service.ImportRuleAsync(Rule("1.1.0", minimum: 4));
        var binding = Assert.Single((await Service.ReadAsync()).Bindings);
        Assert.Equal("1.0.0", binding.Version);
        Assert.True(binding.Enabled);
        Assert.Equal(imported.Digest, binding.Digest);
    }

    [Fact]
    public async Task EnablingRequiresMatchingPlatformAndRootAndReservesBuiltinNames()
    {
        var root = await AddRoot();
        await Service.ImportRuleAsync(Rule(windows: false));
        Assert.Equal("invalid_rule", (await Assert.ThrowsAsync<ShouException>(() => Service.SetRuleAsync(root.Id, "dev.rust-target", true))).Code);
        await Service.ImportRuleAsync(Rule("1.1.0", rootRef: "different"));
        Assert.Equal("invalid_rule", (await Assert.ThrowsAsync<ShouException>(() => Service.SetRuleAsync(root.Id, "dev.rust-target", true, "1.1.0"))).Code);
        Assert.Equal("invalid_rule", (await Assert.ThrowsAsync<ShouException>(() => Service.ImportRuleAsync(Rule(id: "shou.builtin.rust-target")))).Code);
        Assert.Empty((await Service.ReadAsync()).Bindings);
    }

    [Fact]
    public async Task ExclusionsAreCombinedAndEveryChangeInvalidatesTheRevision()
    {
        var root = await AddRoot();
        var before = (await Service.ReadAsync()).Revision;
        await Service.SetExclusionAsync(null, "**/keep", false);
        Assert.NotEqual(before, (await Service.ReadAsync()).Revision);
        await Service.SetExclusionAsync(root.Id, "**/keep", false);
        await Service.SetExclusionAsync(root.Id, "target", false, "project-a");
        var exclusions = await Service.ExclusionsAsync(root.Id);
        Assert.Equal(new[] { "**/keep", "project-a/target" }, exclusions.EffectivePatterns.ToArray());
        var revision = (await Service.ReadAsync()).Revision;
        await Service.SetExclusionAsync(null, "**/keep", false);
        Assert.Equal(revision, (await Service.ReadAsync()).Revision);
        await Service.SetExclusionAsync(root.Id, "target", true, "project-a");
        Assert.Equal(new[] { "**/keep" }, (await Service.ExclusionsAsync(root.Id)).EffectivePatterns.ToArray());
        await Assert.ThrowsAsync<ShouException>(() => Service.SetExclusionAsync(root.Id, "target", false, "../elsewhere"));
        await Assert.ThrowsAsync<ShouException>(() => Service.SetExclusionAsync(null, "target", false, "project-a"));
    }

    [Fact]
    public async Task RemovingWorkspaceRemovesOnlyItsBindingsAndPreservesRulesAndFiles()
    {
        var root = await AddRoot();
        await Service.ImportRuleAsync(Rule());
        await Service.SetRuleAsync(root.Id, "dev.rust-target", true);
        await Service.RemoveWorkspaceAsync(root.Id);
        var configuration = await Service.ReadAsync();
        Assert.Empty(configuration.Workspaces);
        Assert.Empty(configuration.Bindings);
        Assert.Single(configuration.Rules);
        Assert.Single(fs.Entries);
    }

    [Fact]
    public async Task FailedWritesBusyStoreAndCancellationPreserveThePreviousConfiguration()
    {
        _ = await AddRoot();
        var original = store.Records["configuration"].ToArray();
        store.FailWrite = true;
        Assert.Equal("io_error", (await Assert.ThrowsAsync<ShouException>(() => Service.ImportRuleAsync(Rule()))).Code);
        Assert.Equal(original, store.Records["configuration"]);
        store.FailWrite = false;
        store.Busy = true;
        Assert.Equal("store_busy", (await Assert.ThrowsAsync<ShouException>(() => Service.ImportRuleAsync(Rule()))).Code);
        store.Busy = false;
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Service.ImportRuleAsync(Rule(), cancelled.Token));
        Assert.Equal(original, store.Records["configuration"]);
    }

    [Theory]
    [InlineData("version", "9")]
    [InlineData("revision", "\"arbitrary\"")]
    [InlineData("workspaces", "null")]
    [InlineData("rules", "null")]
    [InlineData("approved", "true")]
    [InlineData("global_exclusions", "[\"../escape\"]")]
    public async Task UntrustedConfigurationIsRejectedBeforeAnyUpdate(string key, string json)
    {
        _ = await AddRoot();
        var node = JsonNode.Parse(store.Records["configuration"])!;
        node[key] = JsonNode.Parse(json);
        var bytes = Encoding.UTF8.GetBytes(node.ToJsonString());
        store.Records["configuration"] = bytes;
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => Service.ReadAsync())).Code);
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => Service.ImportRuleAsync(Rule()))).Code);
        Assert.Equal(bytes, store.Records["configuration"]);
    }

    [Fact]
    public async Task TamperedDigestsAndDanglingBindingsCannotBeLoaded()
    {
        var root = await AddRoot();
        await Service.ImportRuleAsync(Rule());
        await Service.SetRuleAsync(root.Id, "dev.rust-target", true);
        var valid = store.Records["configuration"].ToArray();
        foreach (var mutate in new Action<JsonNode>[]
        {
            node => node["rules"]![0]!["digest"] = "sha256:forged",
            node => node["bindings"]![0]!["version"] = "9.0.0",
            node => node["workspaces"] = new JsonArray(),
            node => node["bindings"]!.AsArray().Add(node["bindings"]![0]!.DeepClone())
        })
        {
            var node = JsonNode.Parse(valid)!;
            mutate(node);
            store.Records["configuration"] = Encoding.UTF8.GetBytes(node.ToJsonString());
            Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => Service.ReadAsync())).Code);
        }
    }

    [Theory]
    [InlineData("../configuration")]
    [InlineData("C:configuration")]
    [InlineData("configuration.json")]
    [InlineData("config/escape")]
    [InlineData("Config")]
    public void RecordKeysCannotBecomePaths(string key) => Assert.Throws<ShouException>(() => RecordKey.Validate(key));
}
