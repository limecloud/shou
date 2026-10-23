using System.Security.AccessControl;
using System.Security.Principal;
using Shou.Windows.Core;
using NativeFixture = Shou.Windows.Platform.Tests.WindowsFileSystemTests.NativeFixture;
using FixtureNative = Shou.Windows.Platform.Tests.WindowsFileSystemTests.FixtureNative;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsRecordStoreTests
{
    [WindowsFact]
    public async Task AsyncLeaseKeepsTheCrossProcessLockWithoutKeepingTheAcquisitionToken()
    {
        using var fixture = new NativeFixture();
        var directory = WindowsPath.Parse(Path.Combine(fixture.Root, "Data"));
        var store = new WindowsRecordStore(directory);
        using var cancelled = new CancellationTokenSource();
        var lease = await store.AcquireLeaseAsync(cancelled.Token);
        try
        {
            cancelled.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => lease.WriteAsync("configuration", new byte[] { 9 }, cancelled.Token));
            await lease.WriteAsync("configuration", new byte[] { 1, 2, 3 }, CancellationToken.None);
            Assert.Equal(new byte[] { 1, 2, 3 }, await lease.ReadAsync("configuration", 1024, CancellationToken.None));
            Assert.Equal("store_busy", (await Assert.ThrowsAsync<ShouException>(() => new WindowsRecordStore(directory).ReadAsync("configuration", 1024, default).AsTask())).Code);
        }
        finally { await lease.DisposeAsync(); }
        await Assert.ThrowsAsync<ObjectDisposedException>(() => lease.ReadAsync("configuration", 1024, default).AsTask());
        Assert.Equal(new byte[] { 1, 2, 3 }, await store.ReadAsync("configuration", 1024, default));
    }

    [WindowsFact]
    public async Task MissingReadsDoNotCreateTheDataDirectory()
    {
        using var fixture = new NativeFixture();
        var directory = Path.Combine(fixture.Root, "Data");
        var store = new WindowsRecordStore(WindowsPath.Parse(directory));
        Assert.Null(await store.ReadAsync("configuration", 1024, default));
        Assert.Null(await store.AcquireReadLeaseAsync(default));
        Assert.False(Directory.Exists(directory));
    }

    [WindowsFact]
    public async Task ReadLeaseListsOnlyExactExecutionKeysAndSharesTheMutationLock()
    {
        using var fixture = new NativeFixture();
        var directory = WindowsPath.Parse(Path.Combine(fixture.Root, "Data"));
        var store = new WindowsRecordStore(directory);
        var execution = "execution_" + new string('a', 32);
        await store.UpdateAsync(transaction =>
        {
            transaction.Write(execution, new byte[] { 1, 2 });
            transaction.Write("execution_invalid", new byte[] { 3 });
            transaction.Write("configuration", new byte[] { 4 });
            return true;
        }, default);
        await using var lease = await store.AcquireReadLeaseAsync(default);
        Assert.NotNull(lease);
        Assert.Equal(new[] { execution }, await lease.ListKeysAsync("execution", 4096, default));
        Assert.Equal(new byte[] { 1, 2 }, await lease.ReadAsync(execution, 1024, default));
        Assert.Equal("store_busy", (await Assert.ThrowsAsync<ShouException>(() => store.UpdateAsync(_ => true, default))).Code);
        Assert.Equal("resource_limit", (await Assert.ThrowsAsync<ShouException>(() => lease.ListKeysAsync("execution", 1, default))).Code);
        Assert.Equal(new byte[] { 1, 2 }, File.ReadAllBytes(Path.Combine(directory.Value, execution + ".json")));
    }

    [WindowsFact]
    public async Task PublishesPrivateRecordsAndPreservesThemAcrossStoreInstances()
    {
        using var fixture = new NativeFixture();
        var directory = WindowsPath.Parse(Path.Combine(fixture.Root, "Data"));
        var store = new WindowsRecordStore(directory);
        await store.UpdateAsync(transaction => { transaction.Write("configuration", "{\"version\":1}"u8.ToArray()); return true; }, default);
        var next = new WindowsRecordStore(directory);
        Assert.Equal("{\"version\":1}"u8.ToArray(), await next.ReadAsync("configuration", 1024, default));
        await next.UpdateAsync(transaction => { transaction.Write("configuration", "{\"version\":2}"u8.ToArray()); return true; }, default);
        Assert.Equal("{\"version\":2}"u8.ToArray(), await store.ReadAsync("configuration", 1024, default));
        Assert.Empty(Directory.EnumerateFiles(directory.Value, "pending-*.tmp"));
        var acl = new DirectoryInfo(directory.Value).GetAccessControl();
        Assert.True(acl.AreAccessRulesProtected);
        var permitted = new[] { WindowsIdentity.GetCurrent().User!.Value, "S-1-5-18" };
        foreach (FileSystemAccessRule entry in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            Assert.Contains(entry.IdentityReference.Value, permitted);
    }

    [WindowsFact]
    public async Task ConcurrentLeasesFailWithoutReadingOrChangingRecords()
    {
        using var fixture = new NativeFixture();
        var directory = WindowsPath.Parse(Path.Combine(fixture.Root, "Data"));
        var first = new WindowsRecordStore(directory);
        var second = new WindowsRecordStore(directory);
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        var writer = first.UpdateAsync(transaction =>
        {
            transaction.Write("configuration", new byte[] { 1, 2, 3 });
            entered.Set();
            if (!release.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException();
            return true;
        }, default);
        try
        {
            Assert.True(await Task.Run(() => entered.Wait(TimeSpan.FromSeconds(10))));
            var error = await Assert.ThrowsAsync<ShouException>(() => second.ReadAsync("configuration", 1024, default).AsTask());
            Assert.Equal("store_busy", error.Code);
            var writeError = await Assert.ThrowsAsync<ShouException>(() => second.UpdateAsync(transaction => { transaction.Write("configuration", new byte[] { 9 }); return true; }, default));
            Assert.Equal("store_busy", writeError.Code);
            Assert.ThrowsAny<IOException>(() => Directory.Move(directory.Value, directory.Value + "-replaced"));
        }
        finally { release.Set(); await writer; }
        Assert.Equal(new byte[] { 1, 2, 3 }, await second.ReadAsync("configuration", 1024, default));
    }

    [WindowsFact]
    public async Task RejectsPublicAclsWithoutChangingExistingPermissions()
    {
        using var fixture = new NativeFixture();
        var directory = new DirectoryInfo(Path.Combine(fixture.Root, "Public"));
        directory.Create();
        var security = new DirectorySecurity();
        security.SetOwner(WindowsIdentity.GetCurrent().User!);
        security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { WindowsIdentity.GetCurrent().User!, new SecurityIdentifier(WellKnownSidType.WorldSid, null) })
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        directory.SetAccessControl(security);
        var before = directory.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.Access);
        var store = new WindowsRecordStore(WindowsPath.Parse(directory.FullName));
        var error = await Assert.ThrowsAsync<ShouException>(() => store.UpdateAsync(transaction => { transaction.Write("configuration", new byte[] { 1 }); return true; }, default));
        Assert.Equal("permission_denied", error.Code);
        Assert.Equal(before, directory.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.Access));
        Assert.False(File.Exists(Path.Combine(directory.FullName, "configuration.json")));
    }

    [WindowsFact]
    public async Task RejectsHardLinkedRecordsAndJunctionDataRoots()
    {
        using var fixture = new NativeFixture();
        var directory = WindowsPath.Parse(Path.Combine(fixture.Root, "Data"));
        var store = new WindowsRecordStore(directory);
        await store.UpdateAsync(transaction => { transaction.Write("configuration", new byte[] { 3, 2, 1 }); return true; }, default);
        Assert.True(FixtureNative.CreateHardLink(Path.Combine(fixture.Root, "linked.json"), Path.Combine(directory.Value, "configuration.json"), 0));
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => store.ReadAsync("configuration", 1024, default).AsTask())).Code);
        var junction = Path.Combine(fixture.Root, "junction");
        FixtureNative.CreateJunction(junction, directory.Value);
        try
        {
            var redirected = new WindowsRecordStore(WindowsPath.Parse(junction));
            await Assert.ThrowsAsync<ShouException>(() => redirected.ReadAsync("configuration", 1024, default).AsTask());
        }
        finally { Directory.Delete(junction); }
        Assert.Equal(new byte[] { 3, 2, 1 }, File.ReadAllBytes(Path.Combine(directory.Value, "configuration.json")));
    }

    [WindowsFact]
    public async Task CancelledUpdatesAndInvalidKeysDoNotPublishRecords()
    {
        using var fixture = new NativeFixture();
        var directory = WindowsPath.Parse(Path.Combine(fixture.Root, "Data"));
        var store = new WindowsRecordStore(directory);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.UpdateAsync(transaction => { transaction.Write("configuration", new byte[] { 1 }); return true; }, cancelled.Token));
        Assert.False(Directory.Exists(directory.Value));
        IRecordTransaction? expired = null;
        await store.UpdateAsync(transaction => { expired = transaction; return true; }, default);
        Assert.Throws<ObjectDisposedException>(() => expired!.Read("configuration", 1024));
        Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => store.UpdateAsync(transaction => { transaction.Write("../outside", new byte[] { 1 }); return true; }, default))).Code);
        Assert.False(File.Exists(Path.Combine(fixture.Root, "outside.json")));
    }
}
