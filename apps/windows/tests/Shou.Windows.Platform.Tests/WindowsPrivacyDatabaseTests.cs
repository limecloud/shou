using System.Security.Cryptography;
using System.Security.Principal;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsPrivacyDatabaseTests
{
    [WindowsFact]
    public void PrivacyPinAllowsSqliteWritesButPreventsDeletion()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture(); var file = fixture.Write("generated.sqlite", [1, 2, 3]);
        using (WindowsFileSystem.PinPath(WindowsPath.Parse(file)))
        {
            Assert.Throws<IOException>(() => { using var writer = new FileStream(file, FileMode.Open, FileAccess.Write, FileShare.ReadWrite); });
            Assert.Throws<IOException>(() => File.Delete(file));
            Assert.Throws<IOException>(() => Directory.Move(fixture.Root, fixture.Root + "-replaced"));
        }
        using (WindowsFileSystem.PinPath(WindowsPath.Parse(file), allowFinalSharedWrites: true))
        {
            using var writer = new FileStream(file, FileMode.Open, FileAccess.Write, FileShare.ReadWrite);
            writer.WriteByte(4); writer.Flush(flushToDisk: true);
            Assert.Throws<IOException>(() => File.Delete(file));
        }
        Assert.Equal(new byte[] { 4, 2, 3 }, File.ReadAllBytes(file));
    }

    [WindowsFact]
    public async Task FixedGeneratedSourcePinsAclAndIdentityWithoutChangingDatabaseBytes()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture(); var (policy, source) = CreateSource(fixture);
        using (var database = new PrivacySqlite(source.Path.Value, false, default))
            database.Execute("CREATE TABLE cookies(last_access_utc INTEGER); INSERT INTO cookies VALUES(0),(1);");
        var before = SHA256.HashData(File.ReadAllBytes(source.Path.Value));
        var adapter = new WindowsPrivacyDatabaseInspection(policy, WindowsIdentity.GetCurrent().User!.Value);
        var observed = await adapter.InspectAsync(source, PrivacyWindow.Create(PrivacyTimeRange.AllTime, DateTimeOffset.UtcNow), default);
        Assert.Equal(2, observed.RecordCount); Assert.NotEmpty(observed.Evidence);
        Assert.Contains(observed.Evidence, item => item.Entry.Path == source.Path && item.Entry.Kind == EntryKind.File);
        Assert.All(observed.Evidence, item => Assert.StartsWith("sha256:", item.SecurityDigest));
        Assert.Equal(before, SHA256.HashData(File.ReadAllBytes(source.Path.Value)));
    }

    [WindowsFact]
    public async Task GeneratedWalDatabaseCanBeInspectedWhileWalAndShmAreOpen()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture(); var (policy, source) = CreateSource(fixture);
        using var database = new PrivacySqlite(source.Path.Value, false, default);
        database.Execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE cookies(last_access_utc INTEGER); INSERT INTO cookies VALUES(1);");
        var wal = source.Path.Value + "-wal"; Assert.True(new FileInfo(wal).Length > 32);
        foreach (var suffix in new[] { "-wal", "-shm" })
            fixture.SetFileOwner(Path.GetRelativePath(fixture.Root, source.Path.Value + suffix));
        var before = SharedHash(wal);
        var observed = await new WindowsPrivacyDatabaseInspection(policy, WindowsIdentity.GetCurrent().User!.Value)
            .InspectAsync(source, PrivacyWindow.Create(PrivacyTimeRange.AllTime, DateTimeOffset.UtcNow), default);
        Assert.Equal(1, observed.RecordCount); Assert.Contains(observed.Evidence, item => item.Entry.Path.Value == wal);
        Assert.Equal(before, SharedHash(wal));
    }

    [WindowsFact]
    public async Task GeneratedHardLinkedDatabaseIsRejectedBeforeSqliteAccess()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture(); var (policy, source) = CreateSource(fixture);
        var alias = Path.Combine(fixture.Root, "alias.sqlite"); Assert.True(WindowsFileSystemTests.FixtureNative.CreateHardLink(alias, source.Path.Value, 0));
        var before = File.ReadAllBytes(alias);
        var error = await Assert.ThrowsAsync<ShouException>(() => new WindowsPrivacyDatabaseInspection(policy, WindowsIdentity.GetCurrent().User!.Value)
            .InspectAsync(source, PrivacyWindow.Create(PrivacyTimeRange.AllTime, DateTimeOffset.UtcNow), default));
        Assert.Equal("privacy_identity_unavailable", error.Code); Assert.Equal(before, File.ReadAllBytes(alias));
    }

    private static (WindowsPrivacySourcePolicy Policy, PrivacySourceDefinition Source) CreateSource(WindowsFileSystemTests.NativeFixture fixture)
    {
        var root = WindowsPath.Parse(fixture.Root); var policy = new WindowsPrivacySourcePolicy(new(root, root.Append("Local"), root.Append("Roaming")));
        var source = policy.Create(PrivacyBrowser.Chrome, "Default", PrivacyDatabaseLocation.NetworkCookies);
        fixture.Write(Path.GetRelativePath(fixture.Root, source.Path.Value), []);
        return (policy, source);
    }
    private static byte[] SharedHash(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        return SHA256.HashData(stream);
    }
}
