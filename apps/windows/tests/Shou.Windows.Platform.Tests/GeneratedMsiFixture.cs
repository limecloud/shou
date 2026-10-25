using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

/// <summary>Creates a new, current-user-only MSI containing one generated text file and no custom actions.
/// This fixture never accepts an existing package, product code or installation directory.</summary>
internal sealed class GeneratedMsiFixture : IAsyncDisposable
{
    internal const string OptInVariable = "SHOU_TEST_GENERATED_MSI";
    internal const string EvidenceVariable = "SHOU_TEST_GENERATED_MSI_EVIDENCE";
    private const string Manufacturer = "Shou Generated Test Fixtures";
    private readonly byte[] payload = "Generated MSI fixture; not personal data.\n"u8.ToArray();
    private readonly byte[] marker = "Generated unregistered data; uninstall must not recursively remove this.\n"u8.ToArray();
    private bool installationAttempted;
    private int sequence;
    public string ProductCode { get; } = NewCode();
    public string PackageCode { get; } = NewCode();
    public string ProductName { get; } = "Shou Generated MSI " + Guid.NewGuid().ToString("N");
    public string OwnerSid { get; }
    public string Root { get; }
    public string InstallDirectory => Path.Combine(Root, "installed 内容 with spaces");
    public string InstalledPayload => Path.Combine(InstallDirectory, "payload.txt");
    public string UnregisteredData => Path.Combine(InstallDirectory, "unregistered-data.txt");
    public string ProtectedSibling => Path.Combine(Root, "protected-sibling.txt");
    public string PackagePath => Path.Combine(Root, "generated.msi");

    private GeneratedMsiFixture()
    {
        RequireEnabled();
        using var actor = WindowsIdentity.GetCurrent();
        OwnerSid = actor.User?.Value ?? throw new InvalidOperationException("The fixture needs a current user SID.");
        var evidence = Environment.GetEnvironmentVariable(EvidenceVariable) ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ShouBuild", "generated-msi-evidence");
        var parent = WindowsPath.Parse(Path.GetFullPath(evidence));
        if (new DriveInfo(Path.GetPathRoot(parent.Value)!).DriveType != DriveType.Fixed)
            throw new InvalidOperationException("Generated MSI evidence requires a fixed local Windows drive.");
        Root = Path.Combine(parent.Value, "fixture-" + Guid.NewGuid().ToString("N"));
        new DirectoryInfo(Root).Create(WindowsFileSystemTests.NativeFixture.PrivateDirectorySecurity());
        File.WriteAllBytes(Path.Combine(Root, "payload.txt"), payload);
        File.WriteAllBytes(ProtectedSibling, marker);
        SaveEvidence("created", null);
    }

    public static async Task<GeneratedMsiFixture> InstallAsync()
    {
        var fixture = new GeneratedMsiFixture();
        try
        {
            fixture.RequireAbsentEverywhere();
            fixture.CreatePackage();
            fixture.installationAttempted = true;
            await fixture.RunInstallerAsync(install: true);
            fixture.RequireOwnedInstallation();
            if (!File.Exists(fixture.InstalledPayload) || !File.ReadAllBytes(fixture.InstalledPayload).SequenceEqual(fixture.payload))
                throw new InvalidOperationException("The generated MSI did not install its exact generated payload.");
            File.WriteAllBytes(fixture.UnregisteredData, fixture.marker);
            fixture.SaveEvidence("installed", null);
            return fixture;
        }
        catch (Exception failure)
        {
            try { await fixture.DisposeAsync(); }
            catch (Exception cleanup) { throw new AggregateException($"Generated MSI failed; evidence retained at {fixture.Root}", failure, cleanup); }
            throw new InvalidOperationException($"Generated MSI failed; evidence retained at {fixture.Root}", failure);
        }
    }

    public async Task<InstalledApplication> DiscoverAsync()
    {
        var snapshot = await new ApplicationCatalog(new WindowsApplicationInventory()).ReadAsync();
        File.WriteAllText(Path.Combine(Root, "discovery.json"), JsonSerializer.Serialize(snapshot, ContractJson.Options));
        var application = snapshot.Applications.SingleOrDefault(item => item.Source != ApplicationSource.CurrentUserMsix &&
            item.RegistrationKey == ProductCode) ?? throw new InvalidOperationException(
                "The generated per-user MSI was not discovered; inspect the fixture and source-coverage evidence.");
        if (application.Name != ProductName || application.Publisher != Manufacturer || !application.UsesWindowsInstaller)
            throw new InvalidOperationException("Generated MSI discovery did not preserve the expected registration.");
        return application;
    }

    public void AssertGeneratedBytes(bool installed)
    {
        Assert.Equal(payload, File.ReadAllBytes(Path.Combine(Root, "payload.txt")));
        Assert.Equal(marker, File.ReadAllBytes(ProtectedSibling));
        Assert.Equal(marker, File.ReadAllBytes(UnregisteredData));
        if (installed) Assert.Equal(payload, File.ReadAllBytes(InstalledPayload));
        else Assert.False(File.Exists(InstalledPayload));
    }

    public string? InstalledState() => WindowsApplicationUninstallInspector.ReadMsiProperty(ProductCode, OwnerSid,
        MsiInstallationContext.UserUnmanaged, "State", missingProductAllowed: true);

    public async Task RemoveOwnedInstallationAsync()
    {
        RequireEnabled();
        if (InstalledState() is null) return;
        RequireOwnedInstallation();
        await RunInstallerAsync(install: false);
        if (InstalledState() is not null) throw new InvalidOperationException("The generated MSI remains registered after fixture teardown.");
        SaveEvidence("fixture_uninstalled", null);
    }

    public void SaveEvidence(string stage, ApplicationUninstallExecution? execution)
    {
        var installedState = InstalledState();
        var files = new[] { "payload.txt", "protected-sibling.txt", "generated.msi",
            Path.GetRelativePath(Root, InstalledPayload), Path.GetRelativePath(Root, UnregisteredData) }
            .ToDictionary(name => name.Replace('\\', '/'), name => File.Exists(Path.Combine(Root, name))
                ? Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(Path.Combine(Root, name)))) : null);
        var evidence = new
        {
            schema_version = 1, stage, at_utc = DateTimeOffset.UtcNow, product_code = ProductCode, package_code = PackageCode,
            product_name = ProductName, owner_sid = OwnerSid, os = RuntimeInformation.OSDescription,
            current_user_installation_state = installedState, current_user_installation_present = installedState is not null,
            process_arch = RuntimeInformation.ProcessArchitecture.ToString(), os_arch = RuntimeInformation.OSArchitecture.ToString(),
            native_runtime_checked = true, generated_installer_only = true, public_execution_enabled = WindowsApplicationUninstallMutation.PublicExecutionAvailable,
            files, execution
        };
        File.WriteAllText(Path.Combine(Root, $"{++sequence:D2}-{stage}.json"), JsonSerializer.Serialize(evidence, ContractJson.Options));
    }

    public async ValueTask DisposeAsync()
    {
        // Preserve the MSI, verbose installer logs, record bytes and marker files as local evidence.
        if (installationAttempted) await RemoveOwnedInstallationAsync();
    }

    private void RequireOwnedInstallation()
    {
        if (InstalledState() != "5" || Read("AssignmentType") != "0" || Read("PackageCode") != PackageCode || Read("InstalledProductName") != ProductName ||
            Read("Publisher") != Manufacturer || !WindowsPath.Parse(Read("InstallLocation") ?? "").SamePath(WindowsPath.Parse(InstallDirectory)))
            throw new InvalidOperationException("Refusing fixture cleanup: the registered installation does not match this generated MSI.");
        foreach (var context in new[] { MsiInstallationContext.UserManaged, MsiInstallationContext.Machine })
            if (WindowsApplicationUninstallInspector.ReadMsiProperty(ProductCode, context == MsiInstallationContext.Machine ? null : OwnerSid,
                context, "State", missingProductAllowed: true) is not null)
                throw new InvalidOperationException("Refusing fixture cleanup: the generated product has an unexpected installation context.");
    }

    private string? Read(string property) => WindowsApplicationUninstallInspector.ReadMsiProperty(
        ProductCode, OwnerSid, MsiInstallationContext.UserUnmanaged, property);

    private void RequireAbsentEverywhere()
    {
        foreach (var context in new[] { MsiInstallationContext.UserUnmanaged, MsiInstallationContext.UserManaged, MsiInstallationContext.Machine })
            if (WindowsApplicationUninstallInspector.ReadMsiProperty(ProductCode, context == MsiInstallationContext.Machine ? null : OwnerSid,
                context, "State", missingProductAllowed: true) is not null)
                throw new InvalidOperationException("The randomly generated MSI identity already exists; no package will be installed.");
    }

    private async Task RunInstallerAsync(bool install)
    {
        var log = Path.Combine(Root, $"{++sequence:D2}-{(install ? "install" : "teardown")}.log");
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "msiexec.exe"))
        { UseShellExecute = false, WorkingDirectory = Root };
        // msiexec parses PROPERTY="value with spaces" itself, unlike CommandLineToArgvW.
        // ArgumentList quotes the entire PROPERTY=value token, which MSI rejects with exit 1639.
        // Paths are generated below a WindowsPath-validated root, which cannot contain quotes.
        start.Arguments = (install ? "/i" : "/x") + " \"" + (install ? PackagePath : ProductCode) +
            "\" /qn /norestart REBOOT=ReallySuppress MSIRESTARTMANAGERCONTROL=Disable /L*V \"" + log + "\"";
        if (install)
        {
            // Keep the database neutral/ASCII. Runtime directory properties exercise Unicode and spaces.
            start.Arguments += " ALLUSERS=2 MSIINSTALLPERUSER=1 SHOUFIXTUREDIR=\"" + InstallDirectory + "\" ARPINSTALLLOCATION=\"" + InstallDirectory + "\"";
        }
        using var process = Process.Start(start) ?? throw new InvalidOperationException("The generated MSI installer could not start.");
        // Never kill or abandon an installer on a test timeout. Retain its logs and wait for the real exit.
        await process.WaitForExitAsync(CancellationToken.None);
        if (process.ExitCode != 0) throw new InvalidOperationException($"Generated MSI {(install ? "installation" : "teardown")} returned {process.ExitCode}; log: {log}");
    }

    private void CreatePackage()
    {
        Check(MsiNative.OpenDatabase(PackagePath, 3, out var raw), "create database");
        using var database = new MsiHandle(raw);
        foreach (var sql in new[]
        {
            "CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(0) LOCALIZABLE PRIMARY KEY `Property`)",
            "CREATE TABLE `Directory` (`Directory` CHAR(72) NOT NULL, `Directory_Parent` CHAR(72), `DefaultDir` CHAR(255) NOT NULL LOCALIZABLE PRIMARY KEY `Directory`)",
            "CREATE TABLE `Component` (`Component` CHAR(72) NOT NULL, `ComponentId` CHAR(38), `Directory_` CHAR(72) NOT NULL, `Attributes` SHORT NOT NULL, `Condition` CHAR(255), `KeyPath` CHAR(72) PRIMARY KEY `Component`)",
            "CREATE TABLE `Feature` (`Feature` CHAR(38) NOT NULL, `Feature_Parent` CHAR(38), `Title` CHAR(64) LOCALIZABLE, `Description` CHAR(255) LOCALIZABLE, `Display` SHORT, `Level` SHORT NOT NULL, `Directory_` CHAR(72), `Attributes` SHORT NOT NULL PRIMARY KEY `Feature`)",
            "CREATE TABLE `FeatureComponents` (`Feature_` CHAR(38) NOT NULL, `Component_` CHAR(72) NOT NULL PRIMARY KEY `Feature_`, `Component_`)",
            "CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `Component_` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL LOCALIZABLE, `FileSize` LONG NOT NULL, `Version` CHAR(72), `Language` CHAR(20), `Attributes` SHORT, `Sequence` SHORT NOT NULL PRIMARY KEY `File`)",
            "CREATE TABLE `Media` (`DiskId` SHORT NOT NULL, `LastSequence` LONG NOT NULL, `DiskPrompt` CHAR(64) LOCALIZABLE, `Cabinet` CHAR(255), `VolumeLabel` CHAR(32), `Source` CHAR(72) PRIMARY KEY `DiskId`)",
            "CREATE TABLE `InstallExecuteSequence` (`Action` CHAR(72) NOT NULL, `Condition` CHAR(255), `Sequence` SHORT PRIMARY KEY `Action`)"
        }) Execute(database, sql);
        foreach (var (key, value) in new Dictionary<string, string>
        {
            ["ProductCode"] = ProductCode, ["ProductName"] = ProductName, ["ProductVersion"] = "1.0.0", ["ProductLanguage"] = "1033",
            ["Manufacturer"] = Manufacturer, ["UpgradeCode"] = NewCode(), ["ARPNOMODIFY"] = "1", ["ARPNOREPAIR"] = "1"
        }) Execute(database, "INSERT INTO `Property` (`Property`, `Value`) VALUES (?, ?)", key, value);
        Execute(database, "INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (?, ?, ?)", "TARGETDIR", null, "SourceDir");
        Execute(database, "INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (?, ?, ?)", "LocalAppDataFolder", "TARGETDIR", ".");
        // Missing runtime properties must still target a unique user directory, never the volume root.
        Execute(database, "INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (?, ?, ?)",
            "SHOUFIXTUREDIR", "LocalAppDataFolder", "Shou.Generated." + ProductCode[1..^1] + ":.");
        Execute(database, "INSERT INTO `Component` (`Component`, `ComponentId`, `Directory_`, `Attributes`, `KeyPath`) VALUES (?, ?, ?, ?, ?)",
            "Payload", NewCode(), "SHOUFIXTUREDIR", 256, "PayloadFile");
        Execute(database, "INSERT INTO `Feature` (`Feature`, `Level`, `Attributes`) VALUES (?, ?, ?)", "Main", 1, 0);
        Execute(database, "INSERT INTO `FeatureComponents` (`Feature_`, `Component_`) VALUES (?, ?)", "Main", "Payload");
        Execute(database, "INSERT INTO `File` (`File`, `Component_`, `FileName`, `FileSize`, `Attributes`, `Sequence`) VALUES (?, ?, ?, ?, ?, ?)",
            "PayloadFile", "Payload", "payload.txt", payload.Length, 8192 | 512, 1);
        Execute(database, "INSERT INTO `Media` (`DiskId`, `LastSequence`) VALUES (?, ?)", 1, 1);
        foreach (var (action, order) in new (string, int)[]
        {
            ("CostInitialize", 800), ("FileCost", 900), ("CostFinalize", 1000), ("InstallValidate", 1400), ("InstallInitialize", 1500),
            ("ProcessComponents", 1600), ("UnpublishFeatures", 1800), ("RemoveFiles", 3500), ("InstallFiles", 4000),
            ("RegisterUser", 6000), ("RegisterProduct", 6100), ("PublishFeatures", 6300), ("PublishProduct", 6400), ("InstallFinalize", 6600)
        }) Execute(database, "INSERT INTO `InstallExecuteSequence` (`Action`, `Sequence`) VALUES (?, ?)", action, order);
        Check(MsiNative.GetSummaryInformation(database.Value, null, 6, out var summaryRaw), "open summary");
        using var summary = new MsiHandle(summaryRaw);
        foreach (var (property, value) in new (uint, string)[]
        {
            (2, ProductName), (4, Manufacturer), (7, (RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "Arm64" : "x64") + ";1033"), (9, PackageCode)
        }) Check(MsiNative.SetSummaryProperty(summary.Value, property, 30, 0, 0, value), "set summary text");
        Check(MsiNative.SetSummaryProperty(summary.Value, 14, 3, 500, 0, null), "set installer version");
        Check(MsiNative.SetSummaryProperty(summary.Value, 15, 3, 8, 0, null), "set uncompressed source without elevation");
        Check(MsiNative.PersistSummary(summary.Value), "persist summary");
        Check(MsiNative.Commit(database.Value), "commit database");
    }

    private static void Execute(MsiHandle database, string sql, params object?[] values)
    {
        Check(MsiNative.OpenView(database.Value, sql, out var raw), "open fixture SQL view");
        using var view = new MsiHandle(raw);
        using var record = new MsiHandle(values.Length == 0 ? 0 : MsiNative.CreateRecord(checked((uint)values.Length)));
        if (values.Length > 0 && record.IsInvalid) throw new InvalidOperationException("Cannot allocate a generated MSI record.");
        for (var i = 0; i < values.Length; i++)
            Check(values[i] is int number ? MsiNative.SetInteger(record.Value, (uint)i + 1, number) :
                MsiNative.SetString(record.Value, (uint)i + 1, (string?)values[i]), "bind fixture SQL value");
        Check(MsiNative.ExecuteView(view.Value, record.Value), "execute fixture SQL");
        MsiNative.CloseView(view.Value);
    }

    internal static void RequireEnabled()
    {
        if (Environment.GetEnvironmentVariable(OptInVariable) != "1" || !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) ||
            !Environment.Is64BitProcess || RuntimeInformation.ProcessArchitecture != RuntimeInformation.OSArchitecture ||
            RuntimeInformation.ProcessArchitecture is not (Architecture.X64 or Architecture.Arm64))
            throw new InvalidOperationException("Generated MSI tests require explicit opt-in and matching native Windows 11 x64 or ARM64.");
    }
    private static string NewCode() => Guid.NewGuid().ToString("B").ToUpperInvariant();
    private static void Check(uint result, string operation)
    { if (result != 0) throw new InvalidOperationException($"Generated MSI {operation} failed with Windows Installer code {result}."); }

    private sealed class MsiHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public MsiHandle(uint value) : base(true) => SetHandle((nint)value);
        public uint Value => checked((uint)handle);
        protected override bool ReleaseHandle() => MsiNative.CloseHandle(Value) == 0;
    }

    private static class MsiNative
    {
        [DllImport("msi.dll", EntryPoint = "MsiOpenDatabaseW", CharSet = CharSet.Unicode)]
        internal static extern uint OpenDatabase(string path, nint persistence, out uint database);
        [DllImport("msi.dll", EntryPoint = "MsiDatabaseOpenViewW", CharSet = CharSet.Unicode)]
        internal static extern uint OpenView(uint database, string query, out uint view);
        [DllImport("msi.dll", EntryPoint = "MsiViewExecute")]
        internal static extern uint ExecuteView(uint view, uint record);
        [DllImport("msi.dll", EntryPoint = "MsiViewClose")]
        internal static extern uint CloseView(uint view);
        [DllImport("msi.dll", EntryPoint = "MsiCreateRecord")]
        internal static extern uint CreateRecord(uint fields);
        [DllImport("msi.dll", EntryPoint = "MsiRecordSetStringW", CharSet = CharSet.Unicode)]
        internal static extern uint SetString(uint record, uint field, string? value);
        [DllImport("msi.dll", EntryPoint = "MsiRecordSetInteger")]
        internal static extern uint SetInteger(uint record, uint field, int value);
        [DllImport("msi.dll", EntryPoint = "MsiGetSummaryInformationW", CharSet = CharSet.Unicode)]
        internal static extern uint GetSummaryInformation(uint database, string? path, uint updates, out uint summary);
        [DllImport("msi.dll", EntryPoint = "MsiSummaryInfoSetPropertyW", CharSet = CharSet.Unicode)]
        internal static extern uint SetSummaryProperty(uint summary, uint property, uint type, int value, nint fileTime, string? text);
        [DllImport("msi.dll", EntryPoint = "MsiSummaryInfoPersist")]
        internal static extern uint PersistSummary(uint summary);
        [DllImport("msi.dll", EntryPoint = "MsiDatabaseCommit")]
        internal static extern uint Commit(uint database);
        [DllImport("msi.dll", EntryPoint = "MsiCloseHandle")]
        internal static extern uint CloseHandle(uint handle);
    }
}
