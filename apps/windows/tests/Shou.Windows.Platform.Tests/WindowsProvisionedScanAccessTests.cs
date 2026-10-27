using System.Security.AccessControl;
using System.Security.Principal;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsProvisionedScanAccessTests
{
    private const string Actor = "S-1-5-21-1000";
    private const string Admin = "S-1-5-32-544";

    [WindowsFact]
    public void OnlyTrustedPrincipalsMayWriteOrCreateWritableDescendants()
    {
        foreach (var (aces, expected) in new[] {
            ("(A;;FA;;;S-1-5-21-1000)(A;;FA;;;SY)(A;;FA;;;BA)", true),
            ("(A;;FA;;;S-1-5-21-1000)(A;;FR;;;WD)", true),
            ("(A;;FA;;;S-1-5-21-1000)(A;;FW;;;WD)", false),
            ("(A;OICIIO;FW;;;S-1-5-21-2000)", false),
            ("(A;OICIIO;FA;;;CO)(A;;FA;;;S-1-5-21-1000)", true) })
        {
            var descriptor = new RawSecurityDescriptor("O:BAG:BAD:P" + aces);
            if (expected) WindowsProvisionedScanAccess.ValidateSecurityDescriptor(descriptor, Admin, Actor);
            else Assert.Equal("scan_location_permissions", Assert.Throws<ShouException>(() =>
                WindowsProvisionedScanAccess.ValidateSecurityDescriptor(descriptor, Admin, Actor)).Code);
        }
    }

    [WindowsFact]
    public void ForeignOwnerMismatchedOwnerAndAbsentDaclAreRejected()
    {
        foreach (var (sddl, observed) in new[] { ("O:S-1-5-21-2000G:BAD:P(A;;FA;;;BA)", "S-1-5-21-2000"),
            ("O:BAG:BAD:P(A;;FA;;;BA)", "S-1-5-18"), ("O:BAG:BA", Admin) })
            Assert.Equal("scan_location_permissions", Assert.Throws<ShouException>(() =>
                WindowsProvisionedScanAccess.ValidateSecurityDescriptor(new RawSecurityDescriptor(sddl), observed, Actor)).Code);
    }

    [WindowsFact]
    public async Task PinnedGeneratedRootPreservesBytesAclAndOwnerAndRejectsReplacedIdentity()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture();
        var directory = fixture.CreateDirectory("generated/cache");
        var bytes = fixture.Write("generated/cache/preserved.bin", [1, 2, 3]);
        var info = new DirectoryInfo(directory);
        var security = info.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All);
        var root = await new WindowsFileSystem().InspectAsync(WindowsPath.Parse(directory), default);
        var actor = WindowsIdentity.GetCurrent().User!.Value;
        WindowsProvisionedScanAccess.VerifyPinnedRoot(root, WindowsPath.Parse(fixture.Root), actor, default);
        Assert.Equal(security, info.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All));
        Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(bytes));
        var changed = root with { Identity = new(root.Identity.VolumeSerialNumber, new string('F', 32), root.Identity.OwnerSid) };
        Assert.Throws<ShouException>(() => WindowsProvisionedScanAccess.VerifyPinnedRoot(changed, WindowsPath.Parse(fixture.Root), actor, default));
        var error = await Assert.ThrowsAsync<ShouException>(() => new WindowsFileSystem()
            .VerifyReadOnlyRootAsync(root, WindowsPath.Parse(fixture.Root), actor, default).AsTask());
        Assert.Equal("scan_location_permissions", error.Code); // Arbitrary anchors are not Windows Known Folders.
    }

    [ElevatedWindowsFact]
    public async Task GeneratedAdminOwnedRootCanBeReadWithoutTakingOwnership()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture();
        var directory = fixture.CreateDirectory("generated/cache");
        var info = new DirectoryInfo(directory);
        var security = info.GetAccessControl(); security.SetOwner(new SecurityIdentifier(Admin)); info.SetAccessControl(security);
        var before = info.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All);
        var root = await new WindowsFileSystem().InspectAsync(WindowsPath.Parse(directory), default);
        Assert.Equal(Admin, root.Identity.OwnerSid);
        WindowsProvisionedScanAccess.VerifyPinnedRoot(root, WindowsPath.Parse(fixture.Root), WindowsIdentity.GetCurrent().User!.Value, default);
        Assert.Equal(before, info.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All));
    }

    [WindowsFact]
    public async Task JunctionAncestorCannotBeAdmittedAsAProvisionedRoot()
    {
        using var fixture = new WindowsFileSystemTests.NativeFixture();
        using var outside = new WindowsFileSystemTests.NativeFixture();
        var directory = outside.CreateDirectory("cache");
        var root = await new WindowsFileSystem().InspectAsync(WindowsPath.Parse(directory), default);
        var junction = Path.Combine(fixture.Root, "junction");
        WindowsFileSystemTests.FixtureNative.CreateJunction(junction, outside.Root);
        try
        {
            var redirected = root with { Path = WindowsPath.Parse(Path.Combine(junction, "cache")) };
            Assert.Throws<ShouException>(() => WindowsProvisionedScanAccess.VerifyPinnedRoot(redirected,
                WindowsPath.Parse(fixture.Root), WindowsIdentity.GetCurrent().User!.Value, default));
        }
        finally { Directory.Delete(junction); }
    }
}
