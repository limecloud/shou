using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsApplicationUninstallTests
{
    [Fact]
    public void MsiLaunchUsesAnAbsoluteExecutableAndFixedArgumentsWithoutAShell()
    {
        const string product = "{00000000-0000-0000-0000-000000000001}";
        var start = WindowsApplicationUninstallMutation.MsiStartInfo("C:/Windows/System32", product);
        Assert.Equal(@"C:\Windows\System32\msiexec.exe", start.FileName);
        Assert.Equal(@"C:\Windows\System32", start.WorkingDirectory);
        Assert.False(start.UseShellExecute);
        Assert.Empty(start.Arguments);
        Assert.Equal(new[] { "/x", product, "/qb", "/norestart", "REBOOT=ReallySuppress", "MSIRESTARTMANAGERCONTROL=Disable" }, start.ArgumentList);
    }

    [Theory]
    [InlineData("product & other.exe")]
    [InlineData("{00000000-0000-0000-0000-000000000001} /quiet")]
    [InlineData("00000000-0000-0000-0000-000000000001")]
    public void MsiLaunchRejectsArgumentsThatAreNotAnExactProductCode(string product)
    {
        Assert.Throws<ShouException>(() => WindowsApplicationUninstallMutation.MsiStartInfo("C:/Windows/System32", product));
    }

    [WindowsFact]
    public async Task PreCancelledMutationCannotReadIdentityOrStartAnInstaller()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var result = await new WindowsApplicationUninstallMutation().ApplyAsync(null!, "S-1-0-0", DateTimeOffset.UtcNow + TimeSpan.FromMinutes(1), cancellation.Token);
        Assert.Equal(SystemUninstallOutcome.NotStarted, result.Outcome);
        Assert.Equal("cancelled_before_installer", result.Reason);
    }

    [WindowsFact]
    public async Task MissingInstallationCannotInvokeAnInstaller()
    {
        var result = await new WindowsApplicationUninstallMutation().ApplyAsync(null!, "S-1-0-0", DateTimeOffset.UtcNow + TimeSpan.FromMinutes(1), default);
        Assert.Equal(SystemUninstallOutcome.NotStarted, result.Outcome);
    }

    [WindowsFact]
    public void AbsentGeneratedMsiProductIsNotAnInstalledIdentity()
    {
        var product = Guid.NewGuid().ToString("B").ToUpperInvariant();
        Assert.Null(WindowsApplicationUninstallInspector.ReadMsiProperty(product, null, MsiInstallationContext.Machine, "State", missingProductAllowed: true));
    }

    [WindowsFact]
    public async Task UnsupportedRegistrationDoesNotLaunchAnInstaller()
    {
        var key = "Shou.Tests." + Guid.NewGuid().ToString("N");
        var application = new InstalledApplication(ApplicationCatalog.ApplicationId(ApplicationSource.CurrentUserRegistry, key),
            ApplicationSource.CurrentUserRegistry, key, "Generated fixture", null, null, null, null, false, []);
        var observation = await new WindowsApplicationUninstallInspector().InspectAsync(application, default);
        Assert.Null(observation.Identity);
        Assert.Contains("unsupported_installer", observation.Issues);
    }

    [WindowsFact]
    public async Task PreCancellationDoesNotReadInstallationIdentity()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new WindowsApplicationUninstallInspector().InspectAsync(null!, cancellation.Token));
    }
}
