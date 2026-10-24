using System.Security.AccessControl;
using System.Security.Principal;
using Shou.Windows.Core;
using NativeFixture = Shou.Windows.Platform.Tests.WindowsFileSystemTests.NativeFixture;

namespace Shou.Windows.Platform.Tests;

public sealed class ProvisionedProfileTests
{
    [WindowsFact]
    public async Task FirstDiagnosticWriteDoesNotBreakFirstRecordPublication()
    {
        using var fixture = new NativeFixture();
        var container = WindowsPath.Parse(Path.Combine(fixture.Root, "Shou"));
        var logs = new WindowsRecordStore(container.Append("Diagnostics"), container);
        using (var pinned = logs.PinPrivateDirectory())
        using (logs.OpenDiagnosticFile("application.jsonl")) { }
        var records = new WindowsRecordStore(container.Append("Data"), container);
        await records.UpdateAsync(transaction => { transaction.Write("configuration", new byte[] { 1 }); return true; }, default);
        Assert.Equal(new byte[] { 1 }, await records.ReadAsync("configuration", 8, default));
        var security = new DirectoryInfo(records.Directory.Value).GetAccessControl();
        Assert.Equal(WindowsIdentity.GetCurrent().User!.Value, security.GetOwner(typeof(SecurityIdentifier))!.Value);
        Assert.True(security.AreAccessRulesProtected);
    }

    [WindowsFact]
    public async Task WritableForeignAncestorIsRejectedWithoutRepairOrRecordPublication()
    {
        using var fixture = new NativeFixture();
        var parent = new DirectoryInfo(fixture.CreateDirectory("Local"));
        var security = parent.GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null),
            FileSystemRights.Write, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        parent.SetAccessControl(security);
        var before = parent.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All);
        var container = WindowsPath.Parse(Path.Combine(parent.FullName, "Shou"));
        var records = new WindowsRecordStore(container.Append("Data"), container);
        Assert.Equal("permission_denied", (await Assert.ThrowsAsync<ShouException>(() => records.UpdateAsync(_ => true, default))).Code);
        Assert.False(Directory.Exists(container.Value));
        Assert.Equal(before, parent.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All));
    }

    [ElevatedWindowsFact]
    public async Task ProvisionedAdminOwnedParentAndLegacyContainerCreatePrivateUserLeaves()
    {
        using var fixture = new NativeFixture();
        var parent = new DirectoryInfo(fixture.CreateDirectory("Local"));
        var container = new DirectoryInfo(fixture.CreateDirectory("Local/Shou"));
        foreach (var directory in new[] { parent, container })
        {
            var security = directory.GetAccessControl();
            var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            security.SetOwner(administrators);
            security.AddAccessRule(new FileSystemAccessRule(administrators, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            directory.SetAccessControl(security);
        }
        var before = container.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All);
        var path = WindowsPath.Parse(container.FullName);
        var logs = new WindowsRecordStore(path.Append("Diagnostics"), path);
        using (logs.PinPrivateDirectory())
        using (logs.OpenDiagnosticFile("application.jsonl")) { }
        var records = new WindowsRecordStore(path.Append("Data"), path);
        await records.UpdateAsync(transaction => { transaction.Write("configuration", new byte[] { 7 }); return true; }, default);
        Assert.Equal(new byte[] { 7 }, await records.ReadAsync("configuration", 8, default));
        Assert.Equal(before, container.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All));
        Assert.Equal(WindowsIdentity.GetCurrent().User!.Value, new DirectoryInfo(records.Directory.Value).GetAccessControl().GetOwner(typeof(SecurityIdentifier))!.Value);
        Assert.Equal(WindowsIdentity.GetCurrent().User!.Value, new DirectoryInfo(path.Append("Diagnostics").Value).GetAccessControl().GetOwner(typeof(SecurityIdentifier))!.Value);
    }
}

public sealed class ElevatedWindowsFactAttribute : FactAttribute
{
    public ElevatedWindowsFactAttribute()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) { Skip = "Requires native Windows 11 and an elevated generated-fixture account."; return; }
        using var identity = WindowsIdentity.GetCurrent();
        if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
            Skip = "Admin-owned generated ancestor regression requires an elevated token; do not elevate the product for scanning.";
    }
}
