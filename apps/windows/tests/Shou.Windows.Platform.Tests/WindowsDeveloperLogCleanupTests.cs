using System.Runtime.InteropServices;
using Shou.Windows.Core;
using static Shou.Windows.Platform.Tests.WindowsFileSystemTests;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsDeveloperLogCleanupTests
{
    [WindowsFact]
    public async Task TruncatesExactGeneratedFileAndPreservesIdentityAndSiblings()
    {
        using var fixture = new NativeFixture();
        var path = WindowsPath.Parse(fixture.Write("service.log", new byte[524288]));
        var keep = fixture.Write("database.bin", [1, 2, 3]);
        var native = new WindowsDeveloperLogCleanup("nginx", path);
        var before = await native.InspectAsync(default); Assert.True(before.Writable);
        var service = new DeveloperLogCleanup(native, () => new WindowsRecordStore(WindowsPath.Parse(Path.Combine(fixture.Root, "Records"))));
        var plan = await service.PrepareAsync(); Assert.Equal("succeeded", (await service.ExecuteAsync(plan, plan.Id)).State);
        var after = await native.InspectAsync(default);
        Assert.Equal(before.File.Identity, after.File.Identity); Assert.Equal(0, after.File.LogicalBytes);
        Assert.True(after.File.AllocatedBytes <= before.File.AllocatedBytes); Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(keep));
        File.AppendAllText(path.Value, "new entry\n"); Assert.Equal("new entry\n", File.ReadAllText(path.Value));
        await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan, plan.Id));
    }
    [WindowsFact]
    public async Task AppendReplacementHardLinksAndActiveWritersArePreserved()
    {
        using var fixture = new NativeFixture(); var path = WindowsPath.Parse(fixture.Write("service.log", [1, 2, 3]));
        var native = new WindowsDeveloperLogCleanup("nginx", path); var before = await native.InspectAsync(default);
        File.AppendAllText(path.Value, "appended");
        await Assert.ThrowsAsync<ShouException>(() => native.ClearAsync(before, default));
        before = await native.InspectAsync(default);
        File.Move(path.Value, path.Value + ".old"); File.WriteAllText(path.Value, "replacement");
        fixture.SetFileOwner("service.log");
        await Assert.ThrowsAsync<ShouException>(() => native.ClearAsync(before, default));
        Assert.Equal("replacement", File.ReadAllText(path.Value));
        using (var writer = new FileStream(path.Value, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite))
            Assert.False((await native.InspectAsync(default)).Writable);
        var alias = Path.Combine(fixture.Root, "hard.log");
        Assert.True(FixtureNative.CreateHardLink(alias, path.Value, 0), $"Hard-link fixture failed: {Marshal.GetLastWin32Error()}");
        await Assert.ThrowsAsync<ShouException>(() => native.InspectAsync(default));
    }
    [WindowsFact]
    public async Task ProtectedRecordsAndUnknownFilesCannotBeCleared()
    {
        using var fixture = new NativeFixture();
        var path = WindowsPath.Parse(fixture.Write("source.txt", [1, 2, 3]));
        await Assert.ThrowsAsync<ShouException>(() => new WindowsDeveloperLogCleanup("nginx", path).InspectAsync(default));
        var record = WindowsRecordStore.ForCurrentUser().Directory.Append("protected.log");
        Assert.Throws<ShouException>(() => WindowsDeveloperLogCleanup.RequirePath(record));
    }
}
