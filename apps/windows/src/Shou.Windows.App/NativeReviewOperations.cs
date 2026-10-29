using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

/// <summary>App composition; mutation requires the shared native-acceptance gate and current Core confirmation.</summary>
internal sealed class NativeReviewOperations : ICleanupReviewOperations, ICleanupExecutionOperations, ICleanupHistoryOperations, IConfigurationOperations
{
    private readonly ConfigurationService configuration;
    private readonly CleanupScanService scans;
    private readonly CleanupService cleanup;
    private readonly CleanupHistoryService history;
    private readonly ScanLocationService locations;
    public BuiltinRuleCatalog Catalog { get; }
    public bool ExecutionAvailable => WindowsCleanupMutation.PublicExecutionAvailable;

    public NativeReviewOperations()
    {
        var store = WindowsRecordStore.ForCurrentUser();
        var files = new WindowsFileSystem();
        var scanner = new CleanupScanner(files);
        var validator = RuleResources.CreateValidator();
        var catalog = RuleResources.CreateCatalog(validator, new(WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)),
            WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)), WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData))));
        Catalog = catalog;
        var system = new[] { Environment.SpecialFolder.Windows, Environment.SpecialFolder.ProgramFiles,
            Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.CommonApplicationData }
            .Select(Environment.GetFolderPath).Where(path => !string.IsNullOrEmpty(path)).Select(WindowsPath.Parse).Distinct().ToImmutableArray();
        var protection = new CleanupProtectionContext(store.OwnerSid, WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)), store.Directory, system);
        configuration = new(store, validator, files, store.OwnerSid, catalog: catalog);
        scans = new(store, validator, scanner, protection, catalog: catalog);
        cleanup = new(store, validator, scanner, protection, new WindowsCleanupActivity(), new WindowsCleanupMutation(), catalog: catalog, storageFiles: files);
        history = new(store, validator, files, scanner, store.OwnerSid);
        locations = new(configuration, catalog, files, store.OwnerSid);
    }

    public Task<ImmutableArray<Workspace>> ReadWorkspacesAsync(CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("configuration.read_workspaces", () => Task.Run(async () => (await configuration.ReadAsync(cancellationToken)).Workspaces, cancellationToken));
    public Task<LocationPreparation> PrepareLocationsAsync(CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("locations.prepare", () => Task.Run(() => locations.PrepareAsync(includeProjects: true, cancellationToken), cancellationToken));
    public Task<Configuration> ReadConfigurationAsync(CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("configuration.read", () => Task.Run(() => configuration.ReadAsync(cancellationToken), cancellationToken));
    public Task<Workspace> AddWorkspaceAsync(WindowsPath path, string rootReference, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("configuration.add_workspace", () => Task.Run(() => configuration.AddWorkspaceAsync(path, rootReference, cancellationToken), cancellationToken));
    public Task<bool> RemoveWorkspaceAsync(string workspaceId, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("configuration.remove_workspace", () => Task.Run(() => configuration.RemoveWorkspaceAsync(workspaceId, cancellationToken), cancellationToken));
    public Task<RuleRecord> ImportRuleAsync(ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("configuration.import_rule", () => Task.Run(() => configuration.ImportRuleAsync(bytes, cancellationToken), cancellationToken));
    public Task<RuleBinding> SetRuleAsync(string workspaceId, string ruleId, string version, bool enabled, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("configuration.set_rule", () => Task.Run(() => configuration.SetRuleAsync(workspaceId, ruleId, enabled, version, cancellationToken), cancellationToken));
    public Task<ImmutableArray<string>> SetExclusionAsync(string? workspaceId, string pattern, bool remove, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("configuration.set_exclusion", () => Task.Run(() => configuration.SetExclusionAsync(workspaceId, pattern, remove, cancellationToken: cancellationToken), cancellationToken));
    public Task<CleanupScan> ScanAsync(string workspaceId, ScanBudget budget, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("cleanup.scan", () => Task.Run(() => scans.ScanAsync(workspaceId, budget, cancellationToken), cancellationToken));
    public Task<SystemScan> ScanAllAsync(ImmutableArray<string> workspaceIds, ScanBudget budget, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("cleanup.scan_all", () => Task.Run(() => locations.ScanRegisteredAsync(scans, workspaceIds, budget, cancellationToken), cancellationToken));
    public Task<CleanupPlan> CreatePlanAsync(ImmutableArray<CleanupSelection> selections, CleanupAction action, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("cleanup.plan", () => Task.Run(() => cleanup.CreatePlanAsync(selections, action, cancellationToken), cancellationToken));
    public Task<StorageRemovalReview> ReviewStorageRemovalAsync(ScanSnapshot snapshot, ImmutableArray<WindowsPath> paths, CancellationToken token) =>
        NativeDiagnostics.RunAsync("storage.review", () => Task.Run(() => cleanup.ReviewStorageRemovalAsync(snapshot, paths, token), token));
    public Task<CleanupExecution> ExecuteAsync(string planId, ICleanupConfirmation confirmation, CancellationToken cancellationToken)
        => ExecuteAsync(planId, confirmation, null, cancellationToken);

    public Task<CleanupExecution> ExecuteAsync(string planId, ICleanupConfirmation confirmation, IProgress<CleanupProgress>? progress, CancellationToken cancellationToken)
    {
        if (!ExecutionAvailable) throw new ShouException("unsupported_capability", "Cleanup execution requires a matching native Windows 11 process.");
        return Task.Run(async () =>
        {
            var consent = await cleanup.ConfirmAsync(planId, confirmation, cancellationToken).ConfigureAwait(false);
            return await cleanup.ExecuteAsync(planId, consent, progress, cancellationToken).ConfigureAwait(false);
        }, cancellationToken);
    }
    public Task<CleanupExecution?> ReadExecutionAsync(string planId, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("cleanup.read_execution", () => Task.Run(() => cleanup.ExecutionAsync(planId, cancellationToken), cancellationToken));
    public Task<CleanupHistoryPage> ListAsync(int limit, string? cursor, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("history.list", () => Task.Run(() => history.ListAsync(limit, cursor, cancellationToken), cancellationToken));
    public Task<CleanupHistoryDetail> ShowAsync(string executionId, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("history.show", () => Task.Run(() => history.ShowAsync(executionId, cancellationToken), cancellationToken));
    public Task<CleanupHistoryInspection> InspectAsync(string executionId, ScanBudget budget, CancellationToken cancellationToken) =>
        NativeDiagnostics.RunAsync("history.inspect", () => Task.Run(() => history.InspectAsync(executionId, budget, cancellationToken), cancellationToken));
}
