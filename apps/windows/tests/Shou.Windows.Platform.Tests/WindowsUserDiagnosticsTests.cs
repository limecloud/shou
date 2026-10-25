using Shou.Windows.Core;
using NativeFixture = Shou.Windows.Platform.Tests.WindowsFileSystemTests.NativeFixture;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsUserDiagnosticsTests
{
    [WindowsFact]
    public async Task MissingRecordsAreNotProvisionedByDiagnostics()
    {
        using var fixture = new NativeFixture(); var path = Path.Combine(fixture.Root, "Missing", "Data");
        var report = await new WindowsUserDiagnostics("0.14.0", WindowsPath.Parse(path)).CollectAsync(default);
        Assert.Equal(DiagnosticState.NotConfigured, report.Checks.Single(check => check.Id == "local_records").State);
        Assert.False(Directory.Exists(Path.GetDirectoryName(path)));
    }

    [WindowsFact]
    public async Task ReportPreservesExistingRecordsAndDoesNotCreateALease()
    {
        using var fixture = new NativeFixture(); var path = WindowsPath.Parse(Path.Combine(fixture.Root, "Data"));
        var store = new WindowsRecordStore(path);
        await store.UpdateAsync(transaction => { transaction.Write("configuration", new byte[] { 1, 2 }); return true; }, default);
        var before = Directory.GetFiles(path.Value).ToDictionary(file => file, File.ReadAllBytes);
        var report = await new WindowsUserDiagnostics("0.14.0", path).CollectAsync(default);
        Assert.Equal(DiagnosticState.Normal, report.Checks.Single(check => check.Id == "local_records").State);
        Assert.Equal(before.Keys.Order(), Directory.GetFiles(path.Value).Order());
        foreach (var item in before) Assert.Equal(item.Value, File.ReadAllBytes(item.Key));
    }
}
