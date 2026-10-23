using System.Collections.Immutable;
using Microsoft.Win32;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsApplicationInventoryTests
{
    [WindowsFact]
    public void ReadsOnlyBoundedRegistrationMetadataFromGeneratedRegistryFixtures()
    {
        var path = @"Software\Shou.Tests\Applications_" + Guid.NewGuid().ToString("N");
        using var currentUser = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        try
        {
            using (var parent = currentUser.CreateSubKey(path))
            {
                using var application = parent.CreateSubKey("application");
                application.SetValue("DisplayName", "示例 🧹");
                application.SetValue("DisplayVersion", "1.2.3");
                application.SetValue("EstimatedSize", -1, RegistryValueKind.DWord);
                application.SetValue("InstallLocation", "%LOCALAPPDATA%\\Example", RegistryValueKind.ExpandString);
                application.SetValue("UninstallString", "This value must not be returned or executed");
                application.SetValue("WindowsInstaller", 1, RegistryValueKind.DWord);
                using var hidden = parent.CreateSubKey("hidden");
                hidden.SetValue("DisplayName", "Hidden");
                hidden.SetValue("SystemComponent", 1, RegistryValueKind.DWord);
                using var update = parent.CreateSubKey("update");
                update.SetValue("DisplayName", "Update");
                update.SetValue("ParentKeyName", "application");
                using var oversized = parent.CreateSubKey("oversized");
                oversized.SetValue("DisplayName", new string('x', 5000));
            }
            using var fixture = currentUser.OpenSubKey(path)!;
            var results = ImmutableArray.CreateBuilder<ApplicationRegistration>();
            var issues = new HashSet<string>();
            var inspected = 0;
            WindowsApplicationInventory.ReadRegistry(fixture, ApplicationSource.CurrentUserRegistry, results, () => { inspected++; return true; }, default, issues);
            var app = Assert.Single(results);
            Assert.Equal("示例 🧹", app.DisplayName);
            Assert.Equal(4_398_046_510_080, app.RegisteredEstimatedBytes);
            Assert.Equal("%LOCALAPPDATA%\\Example", app.InstallLocation);
            Assert.Equal(4, inspected);
            Assert.True(app.UsesWindowsInstaller);
            Assert.Contains("invalid_registration_metadata", issues);
        }
        finally { currentUser.DeleteSubKeyTree(path, throwOnMissingSubKey: false); }
    }

    [WindowsFact]
    public void EntryLimitPreservesPartialRegistryCoverage()
    {
        var path = @"Software\Shou.Tests\Applications_" + Guid.NewGuid().ToString("N");
        using var currentUser = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        try
        {
            using var fixture = currentUser.CreateSubKey(path);
            for (var index = 0; index < 3; index++)
            { using var app = fixture.CreateSubKey(index.ToString()); app.SetValue("DisplayName", "Fixture " + index); }
            var result = ImmutableArray.CreateBuilder<ApplicationRegistration>();
            var issues = new HashSet<string>();
            var remaining = 1;
            WindowsApplicationInventory.ReadRegistry(fixture, ApplicationSource.CurrentUserRegistry, result, () =>
            { if (remaining-- > 0) return true; issues.Add("entry_limit"); return false; }, default, issues);
            Assert.Single(result);
            Assert.Contains("entry_limit", issues);
        }
        finally { currentUser.DeleteSubKeyTree(path, throwOnMissingSubKey: false); }
    }

    [WindowsFact]
    public async Task ReadOnlySnapshotReportsAllFourSourcesWithinTheSharedBudget()
    {
        var snapshot = await new WindowsApplicationInventory().ReadAsync(new(MaxEntries: 1), default);
        Assert.Equal(4, snapshot.Sources.Length);
        Assert.InRange(snapshot.Sources.Sum(source => source.InspectedEntries) ?? 0, 0, 1);
        Assert.InRange(snapshot.Registrations.Length, 0, 1);
        Assert.Contains(snapshot.Sources, source => source.State != ApplicationSourceState.Complete);
    }

    [WindowsFact]
    public async Task PreCancelledDiscoveryDoesNotEnumerateRegistrations()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new WindowsApplicationInventory().ReadAsync(new(), cancelled.Token));
    }
}
