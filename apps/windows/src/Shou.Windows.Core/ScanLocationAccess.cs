namespace Shou.Windows.Core;

/// <summary>Read-only admission for OS-provisioned per-user roots; never grants mutation rights.</summary>
public interface IProvisionedScanAccess
{
    ValueTask VerifyReadOnlyRootAsync(FileEntry root, WindowsPath anchor, string ownerSid, CancellationToken cancellationToken);
}

internal static class ScanLocationAccess
{
    internal static async ValueTask VerifyAsync(IWindowsFileSystem files, BuiltinRuleCatalog? catalog,
        FileEntry entry, string ownerSid, CancellationToken cancellationToken)
    {
        if (entry.Kind != EntryKind.Directory || entry.Path.IsVolumeRoot)
            throw new ShouException("unsupported_location", "Choose a local directory without reparse points.");
        if (entry.Identity.OwnerSid == ownerSid) return;
        if (entry.Identity.OwnerSid is not ("S-1-5-18" or "S-1-5-32-544") || catalog is null ||
            !catalog.Locations.Any(location => location.Path == entry.Path) || files is not IProvisionedScanAccess provisioned)
            throw new ShouException("foreign_owner", "This scan location is not owned by the current user.");
        var anchor = new[] { catalog.Directories.LocalAppData, catalog.Directories.RoamingAppData, catalog.Directories.Home }
            .Where(path => entry.Path.IsWithin(path, caseSensitive: true, includeRoot: false))
            .OrderByDescending(path => path.Value.Length).FirstOrDefault();
        if (anchor is null) throw new ShouException("foreign_owner", "The scan location is outside the current user's known folders.");
        await provisioned.VerifyReadOnlyRootAsync(entry, anchor, ownerSid, cancellationToken);
    }
}
