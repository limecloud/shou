using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Private user records. Publication is atomic per record; a lease is not a multi-record transaction.</summary>
public sealed class WindowsRecordStore : IRecordStore
{
    public const int MaximumRecordBytes = 268_435_456;
    private readonly WindowsPath root;
    private readonly WindowsPath? container;
    public string OwnerSid { get; }
    public WindowsPath Directory => root;

    public WindowsRecordStore(WindowsPath directory)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || IntPtr.Size != 8)
            throw new ShouException("unsupported_platform", "Private records require 64-bit Windows 11.");
        if (directory.IsVolumeRoot) throw new ShouException("invalid_argument", "Choose a private application data directory.");
        root = directory;
        using var identity = WindowsIdentity.GetCurrent();
        OwnerSid = identity.User?.Value ?? throw new ShouException("permission_denied", "The current Windows user is unavailable.");
    }

    internal WindowsRecordStore(WindowsPath directory, WindowsPath container) : this(directory) => this.container = container;

    public static WindowsRecordStore ForCurrentUser()
    {
        if (Environment.GetEnvironmentVariable("SHOU_DATA_DIR") is { } selected)
            return new(WindowsPath.Parse(selected));
        var local = WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
        var container = local.Append("Shou");
        return new(container.Append("Data"), container);
    }

    internal static WindowsRecordStore ForDiagnostics()
    {
        if (Environment.GetEnvironmentVariable("SHOU_DIAGNOSTICS_DIR") is { } selected)
            return new(WindowsPath.Parse(selected));
        var container = WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)).Append("Shou");
        return new(container.Append("Diagnostics"), container);
    }

    internal WindowsFileSystem.PinnedPath PinPrivateDirectory()
    {
        if (container is not null) EnsureDirectory(container, requirePrivate: false);
        EnsureDirectory(root, requirePrivate: true);
        var pinned = WindowsFileSystem.PinPath(root, allowFinalSharedWrites: true);
        try { RequireDirectory(root, pinned.Final, requirePrivate: true); return pinned; }
        catch { pinned.Dispose(); throw; }
    }

    internal SafeFileHandle OpenDiagnosticFile(string name)
    {
        if (name is not ("application.jsonl" or "application.jsonl.previous")) throw new ArgumentException("Invalid diagnostic file.", nameof(name));
        using var security = new PrivateSecurity(OwnerSid);
        var path = root.Append(name);
        var handle = NativeMethods.CreateFile(WindowsFileSystem.Extended(path), 0xC0000000 | NativeMethods.ReadControl | NativeMethods.ReadAttributes,
            NativeMethods.ShareRead, security.Attributes, 4, NativeMethods.OpenReparsePoint | NativeMethods.OpenNoRecall, 0);
        try
        {
            if (handle.IsInvalid) throw WindowsFileSystem.NativeError(Marshal.GetLastPInvokeError());
            RequireRecord(WindowsFileSystem.ReadEntry(path, handle), handle, 1_048_576);
            return handle;
        }
        catch { handle.Dispose(); throw; }
    }

    public ValueTask<byte[]?> ReadAsync(string key, int maximumBytes, CancellationToken cancellationToken) =>
        NativeOperationScheduler.RunAsync<byte[]?>(() =>
        {
            RecordKey.Validate(key);
            ValidateLimit(maximumBytes);
            using var lease = OpenLease(create: false, cancellationToken);
            return lease?.Read(key, maximumBytes);
        }, cancellationToken);

    public Task<T> UpdateAsync<T>(Func<IRecordTransaction, T> update, CancellationToken cancellationToken) =>
        NativeOperationScheduler.RunToCompletionAsync(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var lease = OpenLease(create: true, cancellationToken) ?? throw new ShouException("io_error", "Private storage could not be opened.");
            return update(lease);
        }, cancellationToken);

    public async Task<IRecordLease> AcquireLeaseAsync(CancellationToken cancellationToken) =>
        (await AcquireAsync(create: true, cancellationToken))!;

    public async Task<IRecordReadLease?> AcquireReadLeaseAsync(CancellationToken cancellationToken) =>
        await AcquireAsync(create: false, cancellationToken);

    private async Task<AsyncLease?> AcquireAsync(bool create, CancellationToken cancellationToken)
    {
        var lease = await NativeOperationScheduler.RunToCompletionAsync(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            // The lease outlives the acquisition token. Each record operation owns its cancellation boundary.
            return OpenLease(create, CancellationToken.None);
        }, cancellationToken).ConfigureAwait(false);
        if (cancellationToken.IsCancellationRequested)
        {
            lease?.Dispose();
            cancellationToken.ThrowIfCancellationRequested();
        }
        return lease is null ? null : new AsyncLease(lease);
    }

    private Lease? OpenLease(bool create, CancellationToken cancellationToken)
    {
        using var diagnostic = OperationDiagnostics.Start("records.open");
        try
        {
            var lease = OpenLeaseCore(create, cancellationToken);
            diagnostic.Complete(lease is null ? "missing" : "opened");
            return lease;
        }
        catch (Exception error) { diagnostic.Fail(error, "root_or_lock"); throw; }
    }

    private Lease? OpenLeaseCore(bool create, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        WindowsFileSystem.PinnedPath pinned;
        try
        {
            if (create)
            {
                if (container is not null) EnsureDirectory(container, requirePrivate: false);
                EnsureDirectory(root, requirePrivate: true);
            }
            // NT rename may open the destination directory for adding a file. Share writes on
            // this retained directory while the private mutation.lock serializes record operations.
            // Delete sharing stays disabled, so the publication parent cannot be renamed away.
            pinned = WindowsFileSystem.PinPath(root, finalAccess: create ? 0x00100003u : 1, allowFinalSharedWrites: true);
        }
        catch (ShouException error) when (!create && error.Code == "not_found") { return null; }
        catch (ShouException error) when (error.Code == "active_or_inaccessible") { throw Busy(error); }
        try
        {
            RequireDirectory(root, pinned.Final, requirePrivate: true);
            cancellationToken.ThrowIfCancellationRequested();
            using var security = new PrivateSecurity(OwnerSid);
            var handle = NativeMethods.CreateFile(WindowsFileSystem.Extended(root.Append("mutation.lock")), 0xC0000000 | NativeMethods.ReadControl,
                0, security.Attributes, 4, NativeMethods.OpenReparsePoint | NativeMethods.OpenNoRecall, 0);
            if (handle.IsInvalid)
            {
                var error = Marshal.GetLastPInvokeError();
                handle.Dispose();
                if (error is 32 or 33) throw Busy();
                throw WindowsFileSystem.NativeError(error);
            }
            try
            {
                var entry = WindowsFileSystem.ReadEntry(root.Append("mutation.lock"), handle);
                RequireRecord(entry, handle, 0);
                return new Lease(this, pinned, handle, entry.Identity, cancellationToken);
            }
            catch { handle.Dispose(); throw; }
        }
        catch { pinned.Dispose(); throw; }
    }

    private void EnsureDirectory(WindowsPath directory, bool requirePrivate)
    {
        using var diagnostic = OperationDiagnostics.Start("records.ensure_directory");
        var stage = "parent_pin";
        try
        {
            using var parent = WindowsFileSystem.PinPath(directory.Parent!);
            var parentEntry = WindowsFileSystem.ReadEntry(directory.Parent!, parent.Final);
            stage = "parent_security";
            diagnostic.Step(stage, directory.Parent, OwnerKind(parentEntry.Identity.OwnerSid));
            if (container is not null) RequireTrustedContainer(parentEntry, parent.Final);
            else if (parentEntry.Kind != EntryKind.Directory || parentEntry.Identity.OwnerSid != OwnerSid)
                throw new ShouException("permission_denied", "The application data parent must be owned by the current user.");
            stage = "directory_create";
            using var security = new PrivateSecurity(OwnerSid);
            if (!NativeMethods.CreateDirectory(WindowsFileSystem.Extended(directory), security.Attributes))
            {
                var error = Marshal.GetLastPInvokeError();
                if (error != 183) throw WindowsFileSystem.NativeError(error);
            }
            stage = "directory_security";
            using var pinned = WindowsFileSystem.PinPath(directory);
            RequireDirectory(directory, pinned.Final, requirePrivate);
            diagnostic.Complete();
        }
        catch (Exception error) { diagnostic.Fail(error, stage); throw; }
    }

    private void RequireDirectory(WindowsPath path, SafeFileHandle handle, bool requirePrivate)
    {
        var entry = WindowsFileSystem.ReadEntry(path, handle);
        if (!requirePrivate && container is not null) { RequireTrustedContainer(entry, handle); return; }
        if (entry.Kind != EntryKind.Directory || entry.Identity.OwnerSid != OwnerSid)
            throw new ShouException("permission_denied", "Application records require a directory owned by the current user.");
        if (requirePrivate) RequirePrivateAcl(handle, protectedAcl: true);
    }

    private string OwnerKind(string sid) => sid == OwnerSid ? "current_user" : sid switch
    { "S-1-5-18" => "system", "S-1-5-32-544" => "administrators", _ => "other" };

    // A provisioned per-user Known Folder may be owned by SYSTEM/Administrators. Accept only
    // a pinned, non-reparse ancestor with no other write principals. Never repair its ACL/owner.
    // The Data/Diagnostics leaf and every file still require current-user ownership and a private ACL.
    private void RequireTrustedContainer(FileEntry entry, SafeFileHandle handle)
    {
        if (entry.Kind != EntryKind.Directory || OwnerKind(entry.Identity.OwnerSid) == "other") throw PrivateAccess();
        var security = ReadSecurity(handle);
        if (security.Owner?.Value != entry.Identity.OwnerSid || security.DiscretionaryAcl is not { } acl) throw PrivateAccess();
        foreach (var item in acl)
        {
            if (item is not CommonAce ace) throw PrivateAccess();
            if (ace.AceQualifier == AceQualifier.AccessDenied) continue;
            if (ace.AceQualifier != AceQualifier.AccessAllowed) throw PrivateAccess();
            if (ace.SecurityIdentifier.Value == "S-1-3-0" && (ace.AceFlags & AceFlags.InheritOnly) != 0) continue;
            const int writeRights = 0x500D0156;
            // Include inherit-only grants: they can create writable descendants in this ancestor.
            if ((ace.AccessMask & writeRights) != 0 && OwnerKind(ace.SecurityIdentifier.Value) == "other") throw PrivateAccess();
        }
    }

    private static RawSecurityDescriptor ReadSecurity(SafeFileHandle handle)
    {
        var result = NativeMethods.GetPrivateSecurityInfo(handle, 1, 5, out _, 0, out _, 0, out var descriptor);
        if (result != 0) throw WindowsFileSystem.NativeError((int)result);
        try
        {
            var length = NativeMethods.SecurityDescriptorLength(descriptor);
            if (length is 0 or > 65_536) throw PrivateAccess();
            var bytes = new byte[length];
            Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            return new(bytes, 0);
        }
        catch (ArgumentException error) { throw new ShouException("store_corrupt", "The record security descriptor is invalid.", error); }
        finally { NativeMethods.LocalFree(descriptor); }
    }

    private void RequireRecord(FileEntry entry, SafeFileHandle handle, int maximumBytes)
    {
        if (entry.Kind != EntryKind.File || entry.LinkCount != 1 || entry.LogicalBytes < 0 || entry.LogicalBytes > maximumBytes || entry.Identity.OwnerSid != OwnerSid)
            throw new ShouException("store_corrupt", "A record has an invalid type, owner, link count or size.");
        RequirePrivateAcl(handle, protectedAcl: false);
    }

    private void RequirePrivateAcl(SafeFileHandle handle, bool protectedAcl)
    {
        var security = ReadSecurity(handle);
        if (security.Owner?.Value != OwnerSid || security.DiscretionaryAcl is not { } acl ||
            protectedAcl && (security.ControlFlags & ControlFlags.DiscretionaryAclProtected) == 0) throw PrivateAccess();
        var ownerAccess = false;
        foreach (var entry in acl)
        {
            if (entry is not CommonAce ace || ace.AceQualifier != AceQualifier.AccessAllowed ||
                ace.SecurityIdentifier.Value != OwnerSid && ace.SecurityIdentifier.Value != "S-1-5-18" ||
                (ace.AceFlags & AceFlags.InheritOnly) != 0 || (ace.AccessMask & 0x001F01FF) != 0x001F01FF) throw PrivateAccess();
            if (ace.SecurityIdentifier.Value == OwnerSid) ownerAccess = true;
        }
        if (!ownerAccess) throw PrivateAccess();
    }

    private sealed class Lease(WindowsRecordStore store, WindowsFileSystem.PinnedPath pinned, SafeFileHandle mutationLock,
        FileIdentity lockIdentity, CancellationToken cancellationToken) : IRecordTransaction, IDisposable
    {
        private bool disposed;

        private void Check(CancellationToken operationToken)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            cancellationToken.ThrowIfCancellationRequested();
            operationToken.ThrowIfCancellationRequested();
            store.RequireDirectory(store.root, pinned.Final, requirePrivate: true);
            if (WindowsFileSystem.ReadEntry(store.root.Append("mutation.lock"), mutationLock).Identity != lockIdentity)
                throw new ShouException("store_corrupt", "The mutation lease identity changed.");
        }

        public byte[]? Read(string key, int maximumBytes) => Read(key, maximumBytes, cancellationToken);

        internal string[] ListKeys(string prefix, int maximumDirectoryEntries, CancellationToken operationToken)
        {
            Check(operationToken);
            RecordKey.Validate(prefix);
            if (maximumDirectoryEntries is < 1 or > 100_000) throw new ShouException("invalid_argument", "The record directory budget is invalid.");
            var before = WindowsFileSystem.ReadEntry(store.root, pinned.Final);
            HashSet<string> names;
            try { names = NativeFileHandles.Names(pinned.Final, before.IsCaseSensitive, maximumDirectoryEntries, () => Check(operationToken)); }
            catch (ShouException error) when (error.Code == "plan_stale")
            { throw new ShouException("resource_limit", "The private record directory exceeds its entry budget.", error); }
            if (WindowsFileSystem.ReadEntry(store.root, pinned.Final) != before)
                throw new ShouException("source_changed", "The record directory changed during enumeration.");
            return names.Where(name => name.EndsWith(".json", StringComparison.Ordinal) && RecordKey.IsId(name[..^5], prefix))
                .Select(name => name[..^5]).Order(StringComparer.Ordinal).ToArray();
        }

        internal byte[]? Read(string key, int maximumBytes, CancellationToken operationToken)
        {
            Check(operationToken);
            RecordKey.Validate(key);
            ValidateLimit(maximumBytes);
            var path = store.root.Append(key + ".json");
            using var handle = NativeMethods.CreateFile(WindowsFileSystem.Extended(path), NativeMethods.ReadData | NativeMethods.ReadControl | NativeMethods.ReadAttributes,
                NativeMethods.ShareRead, 0, 3, NativeMethods.OpenReparsePoint | NativeMethods.OpenNoRecall, 0);
            if (handle.IsInvalid)
            {
                var error = Marshal.GetLastPInvokeError();
                if (error == 2) return null;
                throw WindowsFileSystem.NativeError(error);
            }
            var before = WindowsFileSystem.ReadEntry(path, handle);
            store.RequireRecord(before, handle, maximumBytes);
            var bytes = new byte[checked((int)before.LogicalBytes)];
            for (var offset = 0; offset < bytes.Length;)
            {
                cancellationToken.ThrowIfCancellationRequested();
                operationToken.ThrowIfCancellationRequested();
                var count = RandomAccess.Read(handle, bytes.AsSpan(offset, Math.Min(65_536, bytes.Length - offset)), offset);
                if (count == 0) throw new ShouException("store_corrupt", "The record changed while it was being read.");
                offset += count;
            }
            if (WindowsFileSystem.ReadEntry(path, handle) != before) throw new ShouException("store_corrupt", "The record changed while it was being read.");
            store.RequirePrivateAcl(handle, protectedAcl: false);
            return bytes;
        }

        public void Write(string key, ReadOnlyMemory<byte> bytes) => Write(key, bytes, cancellationToken);

        internal void Write(string key, ReadOnlyMemory<byte> bytes, CancellationToken operationToken)
        {
            Check(operationToken);
            RecordKey.Validate(key);
            if (bytes.Length > MaximumRecordBytes) throw new ShouException("resource_limit", "The record exceeds its storage budget.");
            _ = Read(key, MaximumRecordBytes, operationToken);
            using var security = new PrivateSecurity(store.OwnerSid);
            var temporary = store.root.Append("pending-" + Guid.NewGuid().ToString("N") + ".tmp");
            using var handle = NativeMethods.CreateFile(WindowsFileSystem.Extended(temporary), 0x40010000 | NativeMethods.ReadControl | NativeMethods.ReadAttributes,
                0, security.Attributes, 1, NativeMethods.OpenReparsePoint | NativeMethods.OpenNoRecall | 0x80000000, 0);
            if (handle.IsInvalid) throw WindowsFileSystem.NativeError(Marshal.GetLastPInvokeError());
            var published = false;
            try
            {
                store.RequireRecord(WindowsFileSystem.ReadEntry(temporary, handle), handle, 0);
                for (var offset = 0; offset < bytes.Length; offset += Math.Min(65_536, bytes.Length - offset))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    operationToken.ThrowIfCancellationRequested();
                    RandomAccess.Write(handle, bytes.Span.Slice(offset, Math.Min(65_536, bytes.Length - offset)), offset);
                }
                if (!NativeMethods.FlushFileBuffers(handle)) throw WindowsFileSystem.NativeError(Marshal.GetLastPInvokeError());
                Check(operationToken);
                var name = Encoding.Unicode.GetBytes(key + ".json\0");
                var offsetName = checked((int)Marshal.OffsetOf<NativeMethods.FileRenameInfo>(nameof(NativeMethods.FileRenameInfo.FileName)));
                var size = checked(offsetName + name.Length);
                var buffer = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.Copy(new byte[size], 0, buffer, size);
                    Marshal.WriteInt32(buffer, 1);
                    Marshal.WriteIntPtr(buffer, checked((int)Marshal.OffsetOf<NativeMethods.FileRenameInfo>(nameof(NativeMethods.FileRenameInfo.RootDirectory))), pinned.Final.DangerousGetHandle());
                    Marshal.WriteInt32(buffer, checked((int)Marshal.OffsetOf<NativeMethods.FileRenameInfo>(nameof(NativeMethods.FileRenameInfo.FileNameLength))), name.Length - 2);
                    Marshal.Copy(name, 0, buffer + offsetName, name.Length);
                    // Win32 FileRenameInfo rejects RootDirectory. The NT operation preserves the
                    // verified parent binding instead of resolving an absolute publication path again.
                    var status = NativeMethods.SetRelativeFileInformation(handle, out _, buffer, (uint)size, NativeMethods.RenameInformation);
                    if (status < 0) throw WindowsFileSystem.NativeError(checked((int)NativeMethods.NtStatusToDosError(status)));
                    published = true;
                }
                finally { Marshal.FreeHGlobal(buffer); }
                if (!NativeMethods.FlushFileBuffers(handle))
                    throw new ShouException("commit_unconfirmed", "The record was published, but its durable outcome must be checked before retrying.");
            }
            finally
            {
                if (!published)
                {
                    var disposition = Marshal.AllocHGlobal(1);
                    try { Marshal.WriteByte(disposition, 1); _ = NativeMethods.SetFileInformation(handle, 4, disposition, 1); }
                    finally { Marshal.FreeHGlobal(disposition); }
                }
            }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            mutationLock.Dispose();
            pinned.Dispose();
        }
    }

    private sealed class AsyncLease(Lease lease) : IRecordLease
    {
        private readonly SemaphoreSlim operations = new(1, 1);
        private bool disposed;

        public async Task<string[]> ListKeysAsync(string prefix, int maximumDirectoryEntries, CancellationToken cancellationToken)
        {
            await operations.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                return await NativeOperationScheduler.RunToCompletionAsync(() => lease.ListKeys(prefix, maximumDirectoryEntries, cancellationToken), cancellationToken).ConfigureAwait(false);
            }
            finally { operations.Release(); }
        }

        public async ValueTask<byte[]?> ReadAsync(string key, int maximumBytes, CancellationToken cancellationToken)
        {
            await operations.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                return await NativeOperationScheduler.RunToCompletionAsync(() => lease.Read(key, maximumBytes, cancellationToken), cancellationToken).ConfigureAwait(false);
            }
            finally { operations.Release(); }
        }

        public async Task WriteAsync(string key, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken)
        {
            await operations.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                await NativeOperationScheduler.RunToCompletionAsync(() => { lease.Write(key, bytes, cancellationToken); return true; }, cancellationToken).ConfigureAwait(false);
            }
            finally { operations.Release(); }
        }

        public async ValueTask DisposeAsync()
        {
            await operations.WaitAsync().ConfigureAwait(false);
            try
            {
                if (disposed) return;
                disposed = true;
                await NativeOperationScheduler.RunToCompletionAsync(() => { lease.Dispose(); return true; }, CancellationToken.None).ConfigureAwait(false);
            }
            finally { operations.Release(); }
        }
    }

    private sealed class PrivateSecurity : IDisposable
    {
        private readonly nint descriptor;
        public nint Attributes { get; }
        public PrivateSecurity(string sid)
        {
            if (!NativeMethods.ConvertSecurityDescriptor($"O:{sid}D:P(A;OICI;FA;;;{sid})(A;OICI;FA;;;SY)", 1, out descriptor, out _))
                throw WindowsFileSystem.NativeError(Marshal.GetLastPInvokeError());
            try
            {
                Attributes = Marshal.AllocHGlobal(Marshal.SizeOf<NativeMethods.SecurityAttributes>());
                Marshal.StructureToPtr(new NativeMethods.SecurityAttributes { Length = Marshal.SizeOf<NativeMethods.SecurityAttributes>(), Descriptor = descriptor }, Attributes, false);
            }
            catch { Marshal.FreeHGlobal(Attributes); NativeMethods.LocalFree(descriptor); throw; }
        }
        public void Dispose() { Marshal.FreeHGlobal(Attributes); NativeMethods.LocalFree(descriptor); }
    }

    private static void ValidateLimit(int limit)
    {
        if (limit is < 0 or > MaximumRecordBytes) throw new ShouException("invalid_argument", "The record read limit is invalid.");
    }
    private static ShouException PrivateAccess() => new("permission_denied", "Shou records must grant access only to the current user and SYSTEM.");
    private static ShouException Busy(Exception? inner = null) => new("store_busy", "Another Shou process is reading or changing local records.", inner);
}
