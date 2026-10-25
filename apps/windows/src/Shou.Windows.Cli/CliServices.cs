using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.Cli;

internal sealed class CliServices
{
    // Enable only after the native mutation, activity, interruption and terminal acceptance evidence is recorded.
    public static bool MutationAvailable => WindowsCleanupMutation.PublicExecutionAvailable;
    public static bool ApplicationUninstallAvailable => WindowsApplicationUninstallMutation.PublicExecutionAvailable;
    public static bool StartupControlAvailable => WindowsStartupControlMutation.PublicExecutionAvailable;
    public WindowsRecordStore Store { get; } = WindowsRecordStore.ForCurrentUser();
    public WindowsFileSystem Files { get; } = new();
    public RuleSchemaValidator Validator { get; } = RuleResources.CreateValidator();
    public BuiltinRuleCatalog Catalog { get; }
    public CliServices() => Catalog = RuleResources.CreateCatalog(Validator, new(
        WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)),
        WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)),
        WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData))));
    public ConfigurationService Configuration => new(Store, Validator, Files, Store.OwnerSid, catalog: Catalog);
    public CleanupHistoryService History => new(Store, Validator, Files, new StorageScanner(Files), Store.OwnerSid);

    public CleanupScanService Preview => new(Store, Validator, new CleanupScanner(Files), Protection, catalog: Catalog);
    public CleanupService Cleanup => new(Store, Validator, new CleanupScanner(Files), Protection, new WindowsCleanupActivity(), new WindowsCleanupMutation(), catalog: Catalog, storageFiles: Files);
    public ScanLocationService Locations => new(Configuration, Catalog, Files, Store.OwnerSid);
    public static ApplicationUninstallReviewer ApplicationReviewer => new(new(new WindowsApplicationInventory()), new WindowsApplicationUninstallInspector(), new WindowsApplicationActivity());
    public ApplicationUninstallPlanner ApplicationPlans => new(Store, ApplicationReviewer, Store.OwnerSid);
    public ApplicationUninstallService ApplicationUninstall => new(Store, ApplicationReviewer, Store.OwnerSid, new WindowsApplicationUninstallMutation());
    public static StartupControlReviewer StartupReviewer => WindowsStartupControlInspector.CreateReviewer();
    public StartupControlService StartupControl => new(Store, StartupReviewer, new WindowsStartupControlMutation(), Store.OwnerSid);
    public PrivacyScanService Privacy
    {
        get
        {
            var policy = new WindowsPrivacySourcePolicy(Catalog.Directories);
            return new(Store, Validator, policy, Files, new WindowsPrivacyDatabaseInspection(policy, Store.OwnerSid),
                new PrivacyBrowserActivity(new WindowsApplicationProcesses()), Store.OwnerSid, Catalog.Directories.Home, Store.Directory);
        }
    }

    private CleanupProtectionContext Protection
    {
        get
        {
            var system = new[] { Environment.SpecialFolder.Windows, Environment.SpecialFolder.ProgramFiles,
                Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.CommonApplicationData }
                .Select(Environment.GetFolderPath).Where(path => !string.IsNullOrEmpty(path)).Select(WindowsPath.Parse).Distinct().ToImmutableArray();
            return new(Store.OwnerSid, WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)), Store.Directory, system);
        }
    }

    public static async Task<byte[]> ReadRuleAsync(string file, CancellationToken cancellationToken)
    {
        WindowsPath path;
        try { path = WindowsPath.Parse(Path.GetFullPath(file)); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        { throw new ShouException("invalid_argument", "The rule file path is invalid.", error); }
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(10));
        try { return await new WindowsFileSystem().ReadRuleFileAsync(path, deadline.Token); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new ShouException("time_limit", "The rule file could not be read within the time limit."); }
    }
}
