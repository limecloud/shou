namespace Shou.Windows.Platform.Tests;

public sealed class WindowsManagedPackageUpdatesTests
{
    [Theory]
    [InlineData("Microsoft.Winget.Source_8wekyb3d8bbwe", true, "Microsoft.PreIndexed.Package", "https://winget.azureedge.net/cache", true)]
    [InlineData("Microsoft.Winget.Source_8wekyb3d8bbwe", true, "Microsoft.PreIndexed.Package", "https://cdn.winget.microsoft.com/cache", true)]
    [InlineData("winget", true, "Microsoft.PreIndexed.Package", "https://winget.azureedge.net/cache", false)]
    [InlineData("Microsoft.Winget.Source_8wekyb3d8bbwe", false, "Microsoft.PreIndexed.Package", "https://winget.azureedge.net/cache", false)]
    [InlineData("Microsoft.Winget.Source_8wekyb3d8bbwe", true, "Microsoft.Rest", "https://winget.azureedge.net/cache", false)]
    [InlineData("Microsoft.Winget.Source_8wekyb3d8bbwe", true, "Microsoft.PreIndexed.Package", "https://example.com/cache", false)]
    public void ExactPredefinedOfficialSourceIsRequired(string id, bool predefined, string type, string argument, bool accepted) =>
        Assert.Equal(accepted, WindowsManagedPackageUpdates.IsOfficialSource(id, predefined, type, argument));

    [Fact]
    public async Task NonWindowsDiscoveryReportsUnavailableWithoutInvokingCom()
    {
        if (OperatingSystem.IsWindows()) return;
        var snapshot = await new WindowsManagedPackageUpdates().ReadAsync(default);
        Assert.False(snapshot.Complete);
        Assert.Empty(snapshot.Packages);
        Assert.Equal("package_manager_unavailable", snapshot.Reason);
    }
}
