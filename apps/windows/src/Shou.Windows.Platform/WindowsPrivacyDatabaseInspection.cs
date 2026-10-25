using System.Collections.Immutable;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed class WindowsPrivacyDatabaseInspection(WindowsPrivacySourcePolicy policy, string ownerSid) : IPrivacyDatabaseInspection
{
    public Task<PrivacyDatabaseObservation> InspectAsync(PrivacySourceDefinition source, PrivacyWindow window, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || IntPtr.Size != 8)
            throw new ShouException("unsupported_platform", "Browser database access requires 64-bit Windows 11.");
        _ = policy.Validate(source); window.Validate();
        return NativeOperationScheduler.RunToCompletionAsync(() =>
        {
            using var identity = WindowsIdentity.GetCurrent();
            if (identity.User?.Value != ownerSid) throw new ShouException("permission_denied", "The Windows actor changed.");
            using var before = SourceAccess.Acquire(policy, source, ownerSid, cancellationToken);
            var inspected = PrivacyDatabaseInspection.Inspect(WindowsFileSystem.Extended(source.Path), source, window, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            using var after = SourceAccess.Acquire(policy, source, ownerSid, cancellationToken);
            if (!before.Evidence.SequenceEqual(after.Evidence)) throw new ShouException("source_changed", "Privacy database evidence changed during inspection.");
            return new PrivacyDatabaseObservation(inspected.Count, inspected.SchemaDigest, after.Evidence);
        }, cancellationToken);
    }

    internal sealed class SourceAccess : IDisposable
    {
        private readonly List<WindowsFileSystem.PinnedPath> pins = [];
        internal ImmutableArray<PrivacyFileEvidence> Evidence { get; private set; } = [];
        internal static SourceAccess Acquire(WindowsPrivacySourcePolicy policy, PrivacySourceDefinition source, string owner, CancellationToken token, bool mutation = false, bool transactionJournal = false)
        {
            if (transactionJournal && !mutation) throw new ArgumentException("Transaction journals are only valid inside the mutation transaction.");
            var root = policy.Validate(source);
            var access = new SourceAccess();
            var evidence = ImmutableArray.CreateBuilder<PrivacyFileEvidence>();
            try
            {
                PrivacyFileEvidence Inspect(WindowsPath path, bool directory, bool journal = false)
                {
                    token.ThrowIfCancellationRequested();
                    // SQLite may maintain SHM/WAL while querying. Never share delete/rename access.
                    var pinned = WindowsFileSystem.PinPath(path, allowFinalSharedWrites: !directory);
                    access.pins.Add(pinned);
                    var entry = WindowsFileSystem.ReadEntry(path, pinned.Final);
                    var createdJournal = journal && transactionJournal && entry.Identity.OwnerSid is "S-1-5-32-544" or "S-1-5-18";
                    // Provisioned Known Folders may have an OS owner. Only the exact AppData
                    // anchor has this exception; every browser directory and database remains user-owned.
                    var provisionedAnchor = directory && path == root.Anchor && entry.Identity.OwnerSid is "S-1-5-32-544" or "S-1-5-18";
                    if (entry.Kind != (directory ? EntryKind.Directory : EntryKind.File) || entry.Identity.OwnerSid != owner && !createdJournal && !provisionedAnchor || !directory && entry.LinkCount != 1)
                        throw Unsafe();
                    var security = SecurityDigest(pinned.Final, owner, createdJournal || provisionedAnchor);
                    if (journal && !transactionJournal && entry.LogicalBytes != 0) throw Unsafe();
                    if (journal && mutation)
                    {
                        // SQLite owns the rollback journal lifecycle. Do not prevent COMMIT from unlinking it.
                        ReleaseJournal(pinned);
                    }
                    // Directory clocks are not content evidence; empty sidecar creation may update them.
                    if (directory) entry = entry with { LogicalBytes = 0, AllocatedBytes = 0, LastWriteUtc = DateTimeOffset.UnixEpoch, ChangeUtc = DateTimeOffset.UnixEpoch };
                    return new(entry, security);
                }
                void ReleaseJournal(WindowsFileSystem.PinnedPath pinned) { access.pins.Remove(pinned); pinned.Dispose(); }
                var current = root.Anchor;
                evidence.Add(Inspect(current, directory: true));
                foreach (var part in source.Path.Parent!.RelativeTo(root.Anchor, caseSensitive: true).Split('/'))
                { current = current.Append(part); evidence.Add(Inspect(current, directory: true)); }
                foreach (var suffix in new[] { "", "-wal", "-shm", "-journal" })
                {
                    PrivacyFileEvidence item;
                    try { item = Inspect(WindowsPath.Parse(source.Path.Value + suffix), directory: false, journal: suffix == "-journal"); }
                    catch (ShouException error) when (suffix.Length > 0 && error.Code == "not_found") { continue; }
                    if (suffix.Length == 0 || suffix == "-wal" && item.Entry.LogicalBytes > 32) evidence.Add(item);
                }
                if (evidence.Count > 32 || evidence.Any(item => item.Entry.Identity.VolumeSerialNumber != evidence[0].Entry.Identity.VolumeSerialNumber)) throw Unsafe();
                access.Evidence = evidence.OrderBy(item => item.Entry.Path.Value, StringComparer.Ordinal).ToImmutableArray();
                return access;
            }
            catch { access.Dispose(); throw; }
        }
        public void Dispose() { for (var index = pins.Count - 1; index >= 0; index--) pins[index].Dispose(); pins.Clear(); }
    }

    private static string SecurityDigest(SafeFileHandle handle, string owner, bool allowSystemOwner = false)
    {
        var code = NativeMethods.GetPrivateSecurityInfo(handle, 1, 5, out _, 0, out _, 0, out var descriptor);
        if (code != 0) throw WindowsFileSystem.NativeError((int)code);
        try
        {
            var length = NativeMethods.SecurityDescriptorLength(descriptor);
            if (length is 0 or > 65_536) throw Unsafe();
            var bytes = new byte[length]; Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            ValidateSecurityDescriptor(new RawSecurityDescriptor(bytes, 0), owner, allowSystemOwner);
            return "sha256:" + Convert.ToHexStringLower(SHA256.HashData(bytes));
        }
        catch (ArgumentException) { throw Unsafe(); }
        finally { NativeMethods.LocalFree(descriptor); }
    }

    internal static void ValidateSecurityDescriptor(RawSecurityDescriptor descriptor, string owner, bool allowSystemOwner = false)
    {
        if (descriptor.Owner?.Value != owner && !(allowSystemOwner && descriptor.Owner?.Value is "S-1-5-18" or "S-1-5-32-544") || descriptor.DiscretionaryAcl is not { } acl) throw Unsafe();
        foreach (var value in acl)
        {
            if (value is not CommonAce ace || ace.IsCallback) throw Unsafe();
            if (ace.AceQualifier == AceQualifier.AccessDenied) continue;
            if (ace.AceQualifier != AceQualifier.AccessAllowed) throw Unsafe();
            if ((ace.AceFlags & AceFlags.InheritOnly) != 0 && ace.SecurityIdentifier.Value == "S-1-3-0") continue;
            // SYSTEM and elevated Administrators are trusted OS principals. Other accounts may only read.
            if ((unchecked((uint)ace.AccessMask) & 0x500D0156u) != 0 && ace.SecurityIdentifier.Value != owner &&
                ace.SecurityIdentifier.Value is not ("S-1-5-18" or "S-1-5-32-544")) throw Unsafe();
        }
    }
    private static ShouException Unsafe() => new("privacy_identity_unavailable", "The privacy source ownership, ACL, links or sidecars are unsafe.");
}
