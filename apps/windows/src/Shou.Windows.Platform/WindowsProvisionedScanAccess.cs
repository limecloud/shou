using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

internal static class WindowsProvisionedScanAccess
{
    internal static async ValueTask VerifyAsync(FileEntry root, WindowsPath anchor, string ownerSid, CancellationToken token)
    {
        _ = await NativeOperationScheduler.RunAsync(() =>
        {
            using var actor = WindowsIdentity.GetCurrent();
            if (actor.User?.Value != ownerSid || !new[] { Environment.SpecialFolder.UserProfile,
                Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolder.ApplicationData }
                .Select(Environment.GetFolderPath).Where(path => !string.IsNullOrEmpty(path))
                .Select(WindowsPath.Parse).Contains(anchor)) throw Unsafe();
            VerifyPinnedRoot(root, anchor, ownerSid, token);
            return true;
        }, token);
    }

    internal static void VerifyPinnedRoot(FileEntry expected, WindowsPath anchor, string ownerSid, CancellationToken token)
    {
        if (anchor.IsVolumeRoot || !expected.Path.IsWithin(anchor, caseSensitive: true, includeRoot: false) ||
            expected.Path.RelativeTo(anchor, caseSensitive: true).Split('/').Length > 32) throw Unsafe();
        var pins = new List<WindowsFileSystem.PinnedPath>();
        try
        {
            var path = anchor;
            foreach (var part in new[] { "" }.Concat(expected.Path.RelativeTo(anchor, caseSensitive: true).Split('/')))
            {
                token.ThrowIfCancellationRequested();
                if (part.Length > 0) path = path.Append(part);
                var pin = WindowsFileSystem.PinPath(path);
                pins.Add(pin);
                var entry = WindowsFileSystem.ReadEntry(path, pin.Final);
                if (entry.Kind != EntryKind.Directory || entry.Identity.VolumeSerialNumber != expected.Identity.VolumeSerialNumber ||
                    path == expected.Path && entry != expected) throw Unsafe();
                ValidateSecurityDescriptor(ReadSecurity(pin.Final), entry.Identity.OwnerSid, ownerSid);
            }
        }
        finally { for (var index = pins.Count - 1; index >= 0; index--) pins[index].Dispose(); }
    }

    private static RawSecurityDescriptor ReadSecurity(SafeFileHandle handle)
    {
        var code = NativeMethods.GetPrivateSecurityInfo(handle, 1, 5, out _, 0, out _, 0, out var descriptor);
        if (code != 0) throw WindowsFileSystem.NativeError((int)code);
        try
        {
            var length = NativeMethods.SecurityDescriptorLength(descriptor);
            if (length is 0 or > 65_536) throw Unsafe();
            var bytes = new byte[length]; Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            return new RawSecurityDescriptor(bytes, 0);
        }
        finally { NativeMethods.LocalFree(descriptor); }
    }

    internal static void ValidateSecurityDescriptor(RawSecurityDescriptor descriptor, string observedOwner, string actor)
    {
        bool Trusted(string sid) => sid == actor || sid is "S-1-5-18" or "S-1-5-32-544";
        if (descriptor.Owner?.Value != observedOwner || !Trusted(observedOwner) || descriptor.DiscretionaryAcl is not { } acl) throw Unsafe();
        foreach (var value in acl)
        {
            if (value is not CommonAce ace || ace.IsCallback) throw Unsafe();
            if (ace.AceQualifier == AceQualifier.AccessDenied) continue;
            if (ace.AceQualifier != AceQualifier.AccessAllowed) throw Unsafe();
            if ((ace.AceFlags & AceFlags.InheritOnly) != 0 && ace.SecurityIdentifier.Value == "S-1-3-0") continue;
            // Inherit-only grants also matter: another account must not create writable descendants.
            if ((unchecked((uint)ace.AccessMask) & 0x500D0156u) != 0 && !Trusted(ace.SecurityIdentifier.Value)) throw Unsafe();
        }
    }

    private static ShouException Unsafe() => new("scan_location_permissions", "The provisioned scan location's identity or permissions could not be verified.");
}
