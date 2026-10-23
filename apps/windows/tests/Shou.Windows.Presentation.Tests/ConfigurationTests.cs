using System.Collections.Immutable;
using System.Text.Json;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed class ConfigurationTests
{
    private static Workspace Location(int index = 1, string root = "developer-workspaces") => new($"ws_{index:x32}", root,
        WindowsPath.Parse($"C:/Users/开发者/Projects{index}"), new(1, index.ToString("x32"), "S-1-5-21-1000"), false, [], DateTimeOffset.UnixEpoch);
    private static RuleRecord Rule(string version = "1.0.0", bool windows = true, string root = "developer-workspaces") => new(JsonSerializer.SerializeToElement(new
    {
        id = "dev.cache", version, name = "Project cache", description = "Rebuildable project output", scope = new { root_ref = root },
        platforms = new[] { windows ? "windows" : "macos" }, risk = new { declared_level = "high" }
    }), "sha256:" + new string('a', 64), DateTimeOffset.UnixEpoch, "local_file");

    private sealed class Operations : IConfigurationOperations
    {
        public Configuration Value = Configuration.Empty with { Workspaces = [Location()], Rules = [Rule()] };
        public RuleRecord Imported = Rule("1.1.0");
        public Func<CancellationToken, Task<Configuration>>? Read;
        public Func<Task>? BeforeWrite;
        public Exception? WriteError;
        public Exception? AfterWriteError;
        public int Reads, Writes;
        public CancellationToken WriteToken, ReadToken;
        public (string Workspace, string Rule, string Version, bool Enabled)? Bound;
        public (string? Workspace, string Pattern, bool Remove)? Exclusion;
        public string? AddedRoot;

        public Task<Configuration> ReadConfigurationAsync(CancellationToken token)
        { Reads++; ReadToken = token; return Read?.Invoke(token) ?? Task.FromResult(Value); }
        private async Task<T> Commit<T>(Func<Configuration, (Configuration Value, T Result)> apply, CancellationToken token)
        {
            Writes++; WriteToken = token;
            if (BeforeWrite is { } before) await before();
            if (WriteError is { } error) throw error;
            var (value, result) = apply(Value);
            Value = value with { Revision = $"config_{Writes:x32}" };
            if (AfterWriteError is { } after) throw after;
            return result;
        }
        public Task<Workspace> AddWorkspaceAsync(WindowsPath path, string rootReference, CancellationToken token) => Commit(value =>
        {
            AddedRoot = rootReference;
            var workspace = Location(2, rootReference) with { Path = path };
            return (value with { Workspaces = value.Workspaces.Add(workspace) }, workspace);
        }, token);
        public Task<bool> RemoveWorkspaceAsync(string id, CancellationToken token) => Commit(value =>
            (value with { Workspaces = value.Workspaces.Where(item => item.Id != id).ToImmutableArray(), Bindings = value.Bindings.Where(item => item.WorkspaceId != id).ToImmutableArray() }, true), token);
        public Task<RuleRecord> ImportRuleAsync(ReadOnlyMemory<byte> bytes, CancellationToken token) => Commit(value =>
            (value with { Rules = value.Rules.Add(Imported) }, Imported), token);
        public Task<RuleBinding> SetRuleAsync(string workspaceId, string ruleId, string version, bool enabled, CancellationToken token) => Commit(value =>
        {
            Bound = (workspaceId, ruleId, version, enabled);
            var binding = new RuleBinding(workspaceId, ruleId, version, Rule().Digest, enabled);
            return (value with { Bindings = value.Bindings.Where(item => item.WorkspaceId != workspaceId || item.RuleId != ruleId).Append(binding).ToImmutableArray() }, binding);
        }, token);
        public Task<ImmutableArray<string>> SetExclusionAsync(string? workspaceId, string pattern, bool remove, CancellationToken token) => Commit(value =>
        {
            Exclusion = (workspaceId, pattern, remove);
            var previous = workspaceId is null ? value.GlobalExclusions : value.Workspaces.Single(item => item.Id == workspaceId).Exclusions;
            var patterns = remove ? previous.Where(item => item != pattern).ToImmutableArray() : previous.Add(pattern);
            return (workspaceId is null ? value with { GlobalExclusions = patterns } : value with
            { Workspaces = value.Workspaces.Select(item => item.Id == workspaceId ? item with { Exclusions = patterns } : item).ToImmutableArray() }, patterns);
        }, token);
    }

    [Fact]
    public async Task EmptyConfigurationCanImportButDoesNotInventLocationsOrEnableRules()
    {
        var operations = new Operations { Value = Configuration.Empty };
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync();
        Assert.True(model.CanEdit); Assert.Empty(model.Workspaces); Assert.Empty(model.Rules);
        await model.ImportRuleAsync(new byte[] { 1 });
        Assert.Equal("1.1.0", model.SelectedRule!.Version);
        Assert.True(model.CanAddLocation); Assert.False(model.CanEnable);
        Assert.Null(model.WorkspaceId); Assert.Empty(operations.Value.Bindings);
        Assert.Equal(2, operations.Reads);
    }

    [Fact]
    public async Task ImportingANewVersionPreservesTheEnabledVersionUntilExplicitlyChanged()
    {
        var operations = new Operations();
        operations.Value = operations.Value with { Bindings = [new(Location().Id, "dev.cache", "1.0.0", Rule().Digest, true)] };
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectRule("dev.cache", "1.0.0");
        Assert.False(model.CanEnable); Assert.True(model.CanDisable);
        await model.ImportRuleAsync(new byte[] { 1 });
        Assert.Equal("1.1.0", model.SelectedRule!.Version);
        Assert.Equal(Location().Id, model.WorkspaceId);
        Assert.Equal("1.0.0", model.SelectedBinding!.Version);
        Assert.True(model.CanEnable); Assert.False(model.CanDisable);
        await model.SetRuleAsync(true);
        Assert.Equal((Location().Id, "dev.cache", "1.1.0", true), operations.Bound);
        Assert.Equal("1.1.0", model.SelectedBinding!.Version);
        await model.SetRuleAsync(false);
        Assert.Equal((Location().Id, "dev.cache", "1.1.0", false), operations.Bound);
        Assert.True(model.CanEnable); Assert.False(model.CanDisable);
    }

    [Fact]
    public async Task BuiltinChoicesFollowTheSelectedLocationAndDefaultEnabledPreferences()
    {
        var validator = new RuleSchemaValidator(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Contracts/rule.schema.json")));
        byte[] Resource(string name) => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Catalog", name + ".json"));
        var home = WindowsPath.Parse("C:/Users/开发者");
        var catalog = new BuiltinRuleCatalog(validator, new(home, home.Append("AppData/Local"), home.Append("AppData/Roaming")), Resource("builtin-rules"), Resource("known-locations"), Resource("project-locations"));
        var operations = new Operations();
        var npm = Location(2, "npm") with { Path = catalog.Locations.Single(value => value.Id == "windows-npm").Path };
        operations.Value = operations.Value with { Workspaces = operations.Value.Workspaces.Add(npm) };
        using var model = new ConfigurationViewModel(operations, catalog);
        await model.LoadAsync(); Assert.DoesNotContain(model.Rules, value => value.Builtin);
        model.SelectWorkspace(Location().Id);
        Assert.Equal(16, model.Rules.Count(value => value.Builtin));
        model.SelectRule("shou.builtin.rust-target", "1.1.0");
        Assert.True(model.SelectedRule!.Builtin); Assert.True(model.CanDisable); Assert.False(model.CanEnable); Assert.False(model.CanAddLocation);
        await model.SetRuleAsync(false);
        Assert.Equal((Location().Id, "shou.builtin.rust-target", "1.1.0", false), operations.Bound);
        Assert.False(model.SelectedBinding!.Enabled); Assert.True(model.CanEnable);
        model.SelectWorkspace(npm.Id);
        Assert.Null(model.SelectedRule);
        Assert.Equal("shou.builtin.windows-npm", Assert.Single(model.Rules.Where(value => value.Builtin)).Id);
    }

    [Fact]
    public async Task FolderRegistrationUsesTheSelectedRuleReferenceAndDoesNotEnableIt()
    {
        var operations = new Operations { Value = Configuration.Empty with { Rules = [Rule()] } };
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectRule("dev.cache", "1.0.0");
        await model.AddLocationAsync(Location(2).Path);
        Assert.Equal("developer-workspaces", operations.AddedRoot);
        Assert.Equal(Location(2).Id, model.WorkspaceId);
        Assert.False(model.CanAddLocation); Assert.True(model.CanEnable);
        Assert.Empty(operations.Value.Bindings);
    }

    [Theory]
    [InlineData(false, "developer-workspaces")]
    [InlineData(true, "unrelated")]
    public async Task InapplicablePlatformOrRootCannotBeEnabled(bool windows, string root)
    {
        var operations = new Operations();
        operations.Value = operations.Value with { Rules = [Rule(windows: windows)] };
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectRule("dev.cache", "1.0.0");
        if (root == "unrelated")
        {
            operations.Value = operations.Value with { Workspaces = [Location(root: root)] };
            await model.LoadAsync(); model.SelectWorkspace(Location().Id);
        }
        Assert.False(model.CanEnable); Assert.False(model.CanDisable);
        await Assert.ThrowsAsync<ShouException>(() => model.SetRuleAsync(true));
        Assert.Equal(0, operations.Writes);
    }

    [Fact]
    public async Task RemovingALocationKeepsImportedRulesAndClearsItsBinding()
    {
        var operations = new Operations();
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectRule("dev.cache", "1.0.0"); await model.SetRuleAsync(true);
        await model.RemoveLocationAsync();
        Assert.Null(model.WorkspaceId); Assert.Empty(model.Workspaces);
        Assert.Single(model.Rules); Assert.Empty(model.Snapshot!.Bindings);
        Assert.True(model.CanAddLocation);
    }

    [Fact]
    public async Task ProjectPreviewIsReadOnlyAndInheritedGlobalPatternsCannotBeRemovedLocally()
    {
        var operations = new Operations();
        operations.Value = operations.Value with { GlobalExclusions = ["**/keep"] };
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectWorkspace(Location().Id);
        Assert.Equal("apps/示例/**", model.PreviewExclusion("**", false, "apps/示例"));
        Assert.Equal(0, operations.Writes);
        await model.AddExclusionAsync("**", false, "apps/示例");
        Assert.Equal((Location().Id, "apps/示例/**", false), operations.Exclusion);
        Assert.Equal(new[] { "**/keep" }, model.GlobalExclusions.ToArray());
        Assert.Equal(new[] { "apps/示例/**" }, model.WorkspaceExclusions.ToArray());
        await Assert.ThrowsAsync<ShouException>(() => model.RemoveExclusionAsync("**/keep", false));
        await model.RemoveExclusionAsync("apps/示例/**", false);
        Assert.Empty(model.WorkspaceExclusions); Assert.Single(model.GlobalExclusions);
        await model.AddExclusionAsync("**/archives", true);
        Assert.Null(operations.Exclusion!.Value.Workspace);
    }

    [Theory]
    [InlineData("../secret", null, false)]
    [InlineData("**", "../project", false)]
    [InlineData("**", "apps/*", false)]
    [InlineData("**", "apps/demo", true)]
    [InlineData("", null, true)]
    public async Task InvalidExclusionPreviewsNeverSave(string pattern, string? project, bool global)
    {
        var operations = new Operations();
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectWorkspace(Location().Id);
        await Assert.ThrowsAsync<ShouException>(() => model.AddExclusionAsync(pattern, global, project));
        Assert.Equal(0, operations.Writes);
    }

    [Fact]
    public async Task WritesRejectConcurrentEditsAndRemainBusyThroughPersistedStateRefresh()
    {
        var write = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var reload = new TaskCompletionSource<Configuration>(TaskCreationOptions.RunContinuationsAsynchronously);
        var reading = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { BeforeWrite = () => write.Task };
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectRule("dev.cache", "1.0.0");
        var invalidations = 0; model.EvidenceInvalidated += (_, _) => invalidations++;
        var task = model.SetRuleAsync(true);
        Assert.True(model.IsSaving); Assert.Equal(1, invalidations);
        Assert.False(operations.WriteToken.CanBeCanceled);
        await Assert.ThrowsAsync<ShouException>(() => model.ImportRuleAsync(new byte[] { 1 }));
        await Assert.ThrowsAsync<ShouException>(() => model.LoadAsync());
        Assert.Throws<ShouException>(() => model.SelectWorkspace(null));
        operations.Read = _ => { reading.SetResult(); return reload.Task; };
        write.SetResult();
        await reading.Task;
        Assert.True(model.IsSaving);
        reload.SetResult(operations.Value with { Bindings = [new(Location().Id, "dev.cache", "1.0.0", Rule().Digest, true)] });
        await task;
        Assert.False(model.IsBusy); Assert.True(model.SelectedBinding!.Enabled);
        Assert.Equal(1, operations.Writes); Assert.Equal(2, operations.Reads);
    }

    [Fact]
    public async Task RefreshInvalidatesPreviousReviewBeforeWaitingEvenWhenConfigurationReadFails()
    {
        var response = new TaskCompletionSource<Configuration>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations();
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectRule("dev.cache", "1.0.0");
        var invalidations = 0; model.EvidenceInvalidated += (_, _) => invalidations++;
        operations.Read = _ => response.Task;
        var task = model.LoadAsync();
        Assert.Equal(1, invalidations); Assert.True(model.IsBusy); Assert.False(model.CanEdit);
        response.SetException(new ShouException("permission_denied", "private diagnostic")); await task;
        Assert.Null(model.Snapshot); Assert.Empty(model.Rules); Assert.False(model.CanEdit);
        Assert.Equal("permission_denied", model.ErrorCode);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedOrCancelledResponseAfterCommitReloadsTheActualEnabledState(bool cancelled)
    {
        var operations = new Operations { AfterWriteError = cancelled ? new OperationCanceledException() : new ShouException("io_error", "private diagnostic") };
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectRule("dev.cache", "1.0.0");
        await model.SetRuleAsync(true);
        Assert.Equal(ConfigurationPageState.Failed, model.State);
        Assert.NotNull(model.ErrorCode); Assert.Null(model.RefreshErrorCode);
        Assert.True(model.SelectedBinding!.Enabled); Assert.False(model.CanEnable); Assert.True(model.CanDisable);
        Assert.Equal(2, operations.Reads);
    }

    [Fact]
    public async Task FailedWriteDoesNotFabricateAnImportedVersion()
    {
        var operations = new Operations { WriteError = new ShouException("version_conflict", "private diagnostic") };
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectRule("dev.cache", "1.0.0");
        await model.ImportRuleAsync(new byte[] { 1 });
        Assert.Equal("version_conflict", model.ErrorCode);
        Assert.Equal("1.0.0", Assert.Single(model.Rules).Version);
        Assert.Equal("1.0.0", model.SelectedRule!.Version);
        Assert.True(model.CanEdit);
    }

    [Fact]
    public async Task AFailedReloadClearsEditableStateUntilAnExplicitSuccessfulRefresh()
    {
        var operations = new Operations();
        using var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectRule("dev.cache", "1.0.0");
        operations.Read = _ => throw new ShouException("store_corrupt", "private diagnostic");
        await model.SetRuleAsync(true);
        Assert.Null(model.ErrorCode); Assert.Equal("store_corrupt", model.RefreshErrorCode);
        Assert.Null(model.Snapshot); Assert.Empty(model.Rules); Assert.Empty(model.Workspaces);
        Assert.False(model.CanEdit); Assert.False(model.CanEnable);
        operations.Read = null; await model.LoadAsync();
        Assert.True(model.CanEdit); Assert.Null(model.RefreshErrorCode);
        Assert.Single(model.Snapshot!.Bindings);
    }

    [Fact]
    public async Task DisposalDuringAWritingOperationDoesNotPretendItWasCancelledOrPublishLateState()
    {
        var write = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { BeforeWrite = () => write.Task };
        var model = new ConfigurationViewModel(operations);
        await model.LoadAsync(); model.SelectRule("dev.cache", "1.0.0");
        var task = model.SetRuleAsync(true);
        var changes = 0; model.PropertyChanged += (_, _) => changes++;
        model.Dispose(); write.SetResult(); await task;
        Assert.False(operations.WriteToken.CanBeCanceled); Assert.True(Assert.Single(operations.Value.Bindings).Enabled);
        Assert.Equal(2, operations.Reads); Assert.Equal(0, changes);
        Assert.Empty(model.Snapshot!.Bindings);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => model.LoadAsync());
    }

    [Fact]
    public async Task DisposalCancelsAReadAndRejectsItsLateSuccessWithoutNotifications()
    {
        var response = new TaskCompletionSource<Configuration>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Read = _ => response.Task };
        var model = new ConfigurationViewModel(operations);
        var task = model.LoadAsync(); var changes = 0;
        model.PropertyChanged += (_, _) => changes++;
        model.Dispose(); response.SetResult(operations.Value); await task;
        Assert.True(operations.ReadToken.IsCancellationRequested);
        Assert.Equal(0, changes); Assert.Null(model.Snapshot);
    }
}
