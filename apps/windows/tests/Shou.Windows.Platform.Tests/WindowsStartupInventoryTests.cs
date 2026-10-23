using System.Text.Json;
using Microsoft.Win32;
using Shou.Windows.Core;
using NativeFixture = Shou.Windows.Platform.Tests.WindowsFileSystemTests.NativeFixture;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsStartupInventoryTests
{
    [Theory]
    [InlineData("\"C:\\Program Files\\示例\\app.exe\" --token=private", "C:\\Program Files\\示例\\app.exe")]
    [InlineData("C:\\Example\\app.exe --token=private", "C:\\Example\\app.exe")]
    [InlineData("C:\\Example\\app.COM", "C:\\Example\\app.COM")]
    [InlineData("C:\\Program Files\\Example\\app.exe --token=private", null)]
    [InlineData("%LOCALAPPDATA%\\app.exe --token=private", null)]
    [InlineData("C:\\%USERNAME%\\app.exe", null)]
    [InlineData("relative.exe --token=private", null)]
    [InlineData("C:relative.exe", null)]
    [InlineData("\\\\server\\share\\app.exe", null)]
    [InlineData("\"C:\\Example\\app.exe\"suffix", null)]
    [InlineData("\"C:\\Example\\app.exe", null)]
    [InlineData(" C:\\Example\\app.exe", null)]
    [InlineData("C:\\Example\\script.cmd --token=private", null)]
    public void ExecutableCluesNeverResolveAmbiguityOrRetainArguments(string command, string? expected)
    {
        var executable = WindowsStartupInventory.ExecutablePath(command);
        Assert.Equal(expected, executable?.Value);
        Assert.DoesNotContain("private", executable?.Value ?? "");
    }

    [WindowsFact]
    public void GeneratedRegistryValuesRemainReadOnlyAndNeverExposeArguments()
    {
        var path = @"Software\Shou.Tests\Startup_" + Guid.NewGuid().ToString("N");
        using var user = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        try
        {
            using var fixture = user.CreateSubKey(path);
            const string command = "\"C:\\Generated fixture\\app.exe\" --token=private-secret";
            fixture.SetValue("示例", command, RegistryValueKind.String);
            fixture.SetValue("Environment", "%LOCALAPPDATA%\\app.exe --token=private-secret", RegistryValueKind.ExpandString);
            fixture.SetValue("WrongType", 42, RegistryValueKind.DWord);
            fixture.SetValue("Oversized", new string('x', 5000), RegistryValueKind.String);
            var result = WindowsStartupInventory.ReadRegistryValues(fixture, StartupSource.CurrentUserRun, 100, default);
            Assert.Equal(2, result.Registrations.Length);
            Assert.Equal(4, result.Sources[0].InspectedEntries);
            Assert.Contains("invalid_registration_metadata", result.Sources[0].Issues);
            Assert.DoesNotContain("private-secret", JsonSerializer.Serialize(result, ContractJson.Options));
            Assert.Equal(command, fixture.GetValue("示例"));
            Assert.Equal("%LOCALAPPDATA%\\app.exe --token=private-secret", fixture.GetValue("Environment", null, RegistryValueOptions.DoNotExpandEnvironmentNames));
            Assert.Equal(4, fixture.ValueCount);
        }
        finally { user.DeleteSubKeyTree(path, throwOnMissingSubKey: false); }
    }

    [WindowsFact]
    public void EntryLimitCannotPretendRemainingRegistryValuesWereRead()
    {
        var path = @"Software\Shou.Tests\Startup_" + Guid.NewGuid().ToString("N");
        using var user = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        try
        {
            using var fixture = user.CreateSubKey(path);
            fixture.SetValue("One", @"C:\Fixture\one.exe");
            fixture.SetValue("Two", @"C:\Fixture\two.exe");
            var result = WindowsStartupInventory.ReadRegistryValues(fixture, StartupSource.CurrentUserRun, 1, default);
            Assert.Single(result.Registrations);
            Assert.Equal(1, result.Sources[0].InspectedEntries);
            Assert.Equal(StartupSourceState.Partial, result.Sources[0].State);
            Assert.Contains("entry_limit", result.Sources[0].Issues);
            Assert.Equal(2, fixture.ValueCount);
        }
        finally { user.DeleteSubKeyTree(path, throwOnMissingSubKey: false); }
    }

    [WindowsFact]
    public async Task GeneratedStartupFolderIsReadWithoutResolvingShortcutsOrChangingBytes()
    {
        using var fixture = new NativeFixture();
        var file = fixture.Write("示例 with spaces.lnk", [1, 2, 3, 4]);
        var result = await WindowsStartupInventory.ReadFolderAsync(new WindowsFileSystem(), WindowsPath.Parse(fixture.Root), StartupSource.CurrentUserStartup, 10, default);
        var item = Assert.Single(result.Registrations);
        Assert.Null(item.ExecutablePath);
        Assert.Equal(file, item.DefinitionPath);
        Assert.Contains("target_not_resolved", item.Issues);
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, File.ReadAllBytes(file));
    }

    [Fact]
    public async Task CancelledDiscoveryDoesNotReadOrOpenCleanupStorage()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new WindowsStartupInventory().ReadAsync(new(), cancelled.Token));
    }

    [Fact]
    public async Task FailedSourceWithUnknownConsumptionCannotReuseTheRemainingBudget()
    {
        var calls = 0;
        var result = await WindowsStartupInventory.ReadSourcesAsync(new(), (source, limit, token) =>
        {
            calls++;
            if (calls == 2) throw new IOException("Unknown consumed entries");
            return Task.FromResult(new StartupInventory([new(source, "Fixture", "Fixture")], [new(source, StartupSourceState.Complete, 1, [])]));
        }, default);
        Assert.Equal(2, calls);
        Assert.Single(result.Registrations);
        Assert.Null(result.Sources[1].InspectedEntries);
        Assert.All(result.Sources.Skip(2), source =>
        {
            Assert.Equal(StartupSourceState.NotRead, source.State);
            Assert.Contains("entry_budget_unknown", source.Issues);
        });
    }

    [Fact]
    public async Task SourceBudgetsShareExactObservedConsumptionIncludingTheScheduler()
    {
        var limits = new List<int>();
        var sources = new List<StartupSource>();
        var result = await WindowsStartupInventory.ReadSourcesAsync(new(MaxEntries: 10), (source, limit, token) =>
        {
            limits.Add(limit);
            sources.Add(source);
            return Task.FromResult(new StartupInventory([], [new(source, StartupSourceState.Complete, 1, [])]));
        }, default);
        Assert.Equal(Enumerable.Range(1, 10).Reverse(), limits);
        Assert.Equal(StartupSource.PackagedStartupTasks, sources[^1]);
        Assert.Equal(10, result.Sources.Sum(source => source.InspectedEntries));
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(11)]
    public async Task InvalidSourceCountsCannotExpandTheBudget(int count)
    {
        var calls = 0;
        var result = await WindowsStartupInventory.ReadSourcesAsync(new(MaxEntries: 10), (source, limit, token) =>
        {
            calls++;
            return Task.FromResult(new StartupInventory([], [new(source, StartupSourceState.Complete, count, [])]));
        }, default);
        Assert.Equal(1, calls);
        Assert.Equal(StartupSourceState.Unavailable, result.Sources[0].State);
        Assert.Contains("startup_inventory_invalid", result.Sources[0].Issues);
        Assert.All(result.Sources.Skip(1), source => Assert.Equal(StartupSourceState.NotRead, source.State));
    }

    [WindowsFact]
    public async Task FixedSourceDiscoveryRetainsTenSourcesWithinOneBudget()
    {
        var result = await new WindowsStartupInventory().ReadAsync(new(MaxEntries: 1), default);
        Assert.Equal(10, result.Sources.Length);
        Assert.InRange(result.Sources.Sum(source => source.InspectedEntries) ?? 0, 0, 1);
        Assert.InRange(result.Registrations.Length, 0, 1);
    }
}
