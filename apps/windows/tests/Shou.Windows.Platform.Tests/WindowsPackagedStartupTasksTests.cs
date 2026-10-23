using System.Text;
using System.Text.Json;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using NativeFixture = Shou.Windows.Platform.Tests.WindowsFileSystemTests.NativeFixture;
using FixtureNative = Shou.Windows.Platform.Tests.WindowsFileSystemTests.FixtureNative;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsPackagedStartupTasksTests
{
    private static readonly StartupPackage Package = new("Example_1.0.0.0_x64__publisher", WindowsPath.Parse(@"C:\Packages\示例"));
    private const string Foundation = "http://schemas.microsoft.com/appx/manifest/foundation/windows10";
    private const string Desktop = "http://schemas.microsoft.com/appx/manifest/desktop/windows10";
    private const string Uap5 = "http://schemas.microsoft.com/appx/manifest/uap/windows10/5";
    private static byte[] Manifest(string extension = "<d:Extension Category=\"windows.startupTask\"><d:StartupTask TaskId=\"Task\" DisplayName=\"示例\" Enabled=\"true\"/></d:Extension>",
        string app = "Executable=\"bin\\app.exe\"", string appId = "App") => Encoding.UTF8.GetBytes(
        $"<Package xmlns=\"{Foundation}\" xmlns:d=\"{Desktop}\" xmlns:u=\"{Uap5}\"><Applications><Application Id=\"{appId}\" {app}><Extensions>{extension}</Extensions></Application></Applications></Package>");
    private static StartupInventory Parse(byte[] bytes, int limit = 100) => WindowsPackagedStartupTasks.Parse(Package, bytes, limit);

    [Theory]
    [InlineData("d")]
    [InlineData("u")]
    public void SupportedNamespacesExposeDeclarationsWithoutClaimingEffectiveState(string prefix)
    {
        var result = Parse(Manifest($"<{prefix}:Extension Category=\"windows.startupTask\"><{prefix}:StartupTask TaskId=\"Task\" DisplayName=\"示例\" Enabled=\"false\"/></{prefix}:Extension>"));
        var item = Assert.Single(result.Registrations);
        Assert.Equal(StartupSource.PackagedStartupTasks, item.Source);
        Assert.Equal(@"C:\Packages\示例\bin\app.exe", item.ExecutablePath);
        Assert.Equal(@"C:\Packages\示例\AppxManifest.xml", item.DefinitionPath);
        Assert.Equal("示例", item.Name);
        Assert.StartsWith(Package.FullName + "!App!", item.RegistrationKey);
        Assert.DoesNotContain("enabled", JsonSerializer.Serialize(item, ContractJson.Options));
        Assert.Equal(3, result.Sources[0].InspectedEntries);
    }

    [Fact]
    public void ExtensionExecutableOverridesTheApplicationAndNeverReadsArgumentsOrResources()
    {
        var item = Assert.Single(Parse(Manifest("<d:Extension Category=\"windows.startupTask\" Executable=\"tools\\start.exe\" Parameters=\"private-secret\"><d:StartupTask TaskId=\"Task\" DisplayName=\"ms-resource:private-secret\"/></d:Extension>")).Registrations);
        Assert.Equal(@"C:\Packages\示例\tools\start.exe", item.ExecutablePath);
        Assert.Equal("Task", item.Name);
        Assert.Contains("task_name_unresolved", item.Issues);
        Assert.DoesNotContain("private-secret", JsonSerializer.Serialize(item, ContractJson.Options));
    }

    [Theory]
    [InlineData("../outside.exe")]
    [InlineData("C:\\other.exe")]
    [InlineData("\\\\server\\share\\app.exe")]
    [InlineData("%LOCALAPPDATA%\\app.exe")]
    [InlineData("$target$.exe")]
    [InlineData("script.cmd")]
    [InlineData("app.exe --secret")]
    [InlineData("bin\\NUL.exe")]
    public void ExecutableCluesCannotEscapeTheRegisteredPackageOrExpandCommands(string executable)
    {
        var item = Assert.Single(Parse(Manifest(app: $"Executable=\"{executable}\"")).Registrations);
        Assert.Null(item.ExecutablePath);
        Assert.Contains("executable_unresolved", item.Issues);
    }

    [Fact]
    public void IdentityBindsInstalledVersionApplicationAndExactTaskCase()
    {
        var bytes = Manifest();
        var original = Assert.Single(Parse(bytes).Registrations).RegistrationKey;
        var updated = Assert.Single(WindowsPackagedStartupTasks.Parse(Package with { FullName = "Example_2.0.0.0_x64__publisher" }, bytes, 100).Registrations).RegistrationKey;
        var otherApp = Assert.Single(Parse(Manifest(appId: "Other")).Registrations).RegistrationKey;
        var otherCase = Assert.Single(Parse(Manifest("<d:Extension Category=\"windows.startupTask\"><d:StartupTask TaskId=\"TASK\"/></d:Extension>")).Registrations).RegistrationKey;
        Assert.Equal(4, new[] { original, updated, otherApp, otherCase }.Distinct().Count());
    }

    [Fact]
    public void LongTaskIdsHaveBoundedKeysAndDisplayFallbacks()
    {
        var item = Assert.Single(Parse(Manifest("<d:Extension Category=\"windows.startupTask\"><d:StartupTask TaskId=\"" + new string('x', 32767) + "\"/></d:Extension>")).Registrations);
        Assert.Equal("App", item.Name);
        Assert.InRange(item.RegistrationKey.Length, 1, 1024);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(" Task")]
    [InlineData("Task ")]
    [InlineData("bad&#x202e;id")]
    public void InvalidTaskIdentifiersAreOmittedWithPartialCoverage(string id)
    {
        var result = Parse(Manifest($"<d:Extension Category=\"windows.startupTask\"><d:StartupTask TaskId=\"{id}\"/></d:Extension>"));
        Assert.Empty(result.Registrations);
        Assert.Contains("invalid_registration_metadata", result.Sources[0].Issues);
    }

    [Fact]
    public void OtherCategoriesAndUnknownNamespacesCannotInventDeclarations()
    {
        Assert.Empty(Parse(Manifest("<d:Extension Category=\"windows.other\"><d:StartupTask TaskId=\"Task\"/></d:Extension>")).Registrations);
        var unknown = Parse(Manifest("<x:Extension xmlns:x=\"urn:unknown\" Category=\"windows.startupTask\"><x:StartupTask TaskId=\"Task\"/></x:Extension>"));
        Assert.Empty(unknown.Registrations);
        Assert.Contains("unsupported_startup_declaration", unknown.Sources[0].Issues);
    }

    [Fact]
    public void DuplicateOrAmbiguousDeclarationsCannotCreateIndependentRegistrations()
    {
        const string extension = "<d:Extension Category=\"windows.startupTask\"><d:StartupTask TaskId=\"Task\"/></d:Extension>";
        var duplicate = Parse(Manifest(extension + extension));
        Assert.Single(duplicate.Registrations);
        Assert.Contains("duplicate_registration", duplicate.Sources[0].Issues);
        var ambiguous = Parse(Manifest("<d:Extension Category=\"windows.startupTask\"><d:StartupTask TaskId=\"One\"/><d:StartupTask TaskId=\"Two\"/></d:Extension>"));
        Assert.Empty(ambiguous.Registrations);
        Assert.Contains("invalid_registration_metadata", ambiguous.Sources[0].Issues);
    }

    [Fact]
    public void XmlIsBoundedAndCannotReadEntitiesOrAcceptMalformedEncoding()
    {
        var invalid = new[]
        {
            Encoding.UTF8.GetBytes("<Package/>"), Encoding.UTF8.GetBytes("<Package>"), new byte[] { 255, 255, 255 },
            Encoding.UTF8.GetBytes("<!DOCTYPE Package [<!ENTITY secret SYSTEM 'file:///private'>]>" + Encoding.UTF8.GetString(Manifest())),
            new byte[WindowsPackagedStartupTasks.MaximumManifestBytes + 1]
        };
        foreach (var bytes in invalid)
            Assert.Equal("invalid_registration_metadata", Assert.Throws<ShouException>(() => Parse(bytes)).Code);
    }

    [Fact]
    public void ApplicationsExtensionsAndTaskDeclarationsAllConsumeTheBudget()
    {
        var result = Parse(Manifest(), 2);
        Assert.Empty(result.Registrations);
        Assert.Equal(2, result.Sources[0].InspectedEntries);
        Assert.Equal(StartupSourceState.Partial, result.Sources[0].State);
        Assert.Contains("entry_limit", result.Sources[0].Issues);
        Assert.Single(Parse(Manifest(), 3).Registrations);
    }

    private sealed class Reader(StartupPackage[] packages) : IPackagedStartupReader
    {
        public int Reads { get; private set; }
        public bool EnumerationDisposed { get; private set; }
        public bool Current { get; init; } = true;
        public byte[] Bytes { get; init; } = Manifest();
        public Action? OnRead { get; init; }
        public IEnumerable<StartupPackage> ReadPackages(CancellationToken token)
        {
            try { foreach (var package in packages) { token.ThrowIfCancellationRequested(); yield return package; } }
            finally { EnumerationDisposed = true; }
        }
        public byte[] ReadManifest(StartupPackage package, CancellationToken token) { Reads++; OnRead?.Invoke(); return Bytes; }
        public bool IsCurrent(StartupPackage package, CancellationToken token) => Current;
    }

    [Fact]
    public void ExcludedPackagesAndFailuresConsumeBudgetWithoutReadingTheirFiles()
    {
        var reader = new Reader([new(null, null, Excluded: true), new(null, null, Error: "permission_denied"), Package]);
        var result = WindowsPackagedStartupTasks.Read(reader, 10, default);
        Assert.Equal(1, reader.Reads);
        Assert.Single(result.Registrations);
        Assert.Equal(6, result.Sources[0].InspectedEntries);
        Assert.Contains("permission_denied", result.Sources[0].Issues);
        Assert.True(reader.EnumerationDisposed);
    }

    [Fact]
    public void ManyDistinctFailuresRetainPartialCoverageWithBoundedIssueMetadata()
    {
        var reader = new Reader(Enumerable.Range(0, 20).Select(index => new StartupPackage(null, null, Error: "fixture_error_" + index)).ToArray());
        var result = WindowsPackagedStartupTasks.Read(reader, 100, default);
        Assert.Equal(StartupSourceState.Partial, result.Sources[0].State);
        Assert.Equal(20, result.Sources[0].InspectedEntries);
        Assert.Equal(16, result.Sources[0].Issues.Length);
        Assert.Contains("additional_issues", result.Sources[0].Issues);
    }

    [Fact]
    public void ChangedPackageRegistrationDropsItsCandidatesWithoutLosingConsumedBudget()
    {
        var reader = new Reader([Package]) { Current = false };
        var result = WindowsPackagedStartupTasks.Read(reader, 10, default);
        Assert.Empty(result.Registrations);
        Assert.Equal(4, result.Sources[0].InspectedEntries);
        Assert.Contains("registration_changed", result.Sources[0].Issues);
    }

    [Fact]
    public void ExhaustedPackageBudgetNeverReadsTheNextManifest()
    {
        var reader = new Reader([Package, Package]);
        var result = WindowsPackagedStartupTasks.Read(reader, 4, default);
        Assert.Single(result.Registrations);
        Assert.Equal(1, reader.Reads);
        Assert.Equal(4, result.Sources[0].InspectedEntries);
        Assert.Contains("entry_limit", result.Sources[0].Issues);
    }

    [Fact]
    public void ExhaustedBudgetAfterPackageMetadataDoesNotOpenItsManifest()
    {
        var reader = new Reader([Package]);
        var result = WindowsPackagedStartupTasks.Read(reader, 1, default);
        Assert.Empty(result.Registrations);
        Assert.Equal(0, reader.Reads);
        Assert.Contains("entry_limit", result.Sources[0].Issues);
    }

    [Fact]
    public void CancelledManifestReadPublishesNothingAndDisposesEnumeration()
    {
        using var cancelled = new CancellationTokenSource();
        var reader = new Reader([Package]) { OnRead = cancelled.Cancel };
        Assert.ThrowsAny<OperationCanceledException>(() => WindowsPackagedStartupTasks.Read(reader, 10, cancelled.Token));
        Assert.True(reader.EnumerationDisposed);
        Assert.Equal(1, reader.Reads);
    }

    [Fact]
    public void PreCancellationNeverCreatesTheNativePackageManager()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => WindowsPackagedStartupTasks.Read(10, cancelled.Token));
    }

    [WindowsFact]
    public void GeneratedManifestReadingIsBoundedAndAcceptsReadOnlyHardLinkMetadata()
    {
        using var fixture = new NativeFixture();
        var bytes = Manifest();
        var original = fixture.Write("AppxManifest.xml", bytes);
        var linked = Path.Combine(fixture.Root, "linked.xml");
        Assert.True(FixtureNative.CreateHardLink(linked, original, 0));
        Assert.Equal(bytes, WindowsFileSystem.ReadMetadataFile(WindowsPath.Parse(linked), bytes.Length, requireSingleLink: false, default));
        Assert.Equal("resource_limit", Assert.Throws<ShouException>(() => WindowsFileSystem.ReadMetadataFile(WindowsPath.Parse(linked), bytes.Length - 1, requireSingleLink: false, default)).Code);
        Assert.Equal(bytes, File.ReadAllBytes(original));
    }

    [WindowsFact]
    public void GeneratedManifestAncestorsCannotTraverseAJunction()
    {
        using var fixture = new NativeFixture();
        using var outside = new NativeFixture();
        var bytes = Manifest();
        var original = outside.Write("AppxManifest.xml", bytes);
        var junction = Path.Combine(fixture.Root, "junction");
        FixtureNative.CreateJunction(junction, outside.Root);
        try
        {
            Assert.Equal("unsafe_path", Assert.Throws<ShouException>(() => WindowsFileSystem.ReadMetadataFile(
                WindowsPath.Parse(Path.Combine(junction, "AppxManifest.xml")), WindowsPackagedStartupTasks.MaximumManifestBytes, false, default)).Code);
        }
        finally { Directory.Delete(junction); }
        Assert.Equal(bytes, File.ReadAllBytes(original));
    }
}
