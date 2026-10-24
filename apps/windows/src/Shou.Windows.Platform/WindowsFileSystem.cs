using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed class WindowsFileSystem : IWindowsFileSystem
{
    public bool VerifiesDirectoryEntries => true;
    public ValueTask<byte[]> ReadRuleFileAsync(WindowsPath path, CancellationToken cancellationToken) =>
        NativeOperationScheduler.RunAsync(() => ReadMetadataFile(path, RuleSchemaValidator.MaximumRuleBytes, requireSingleLink: true, cancellationToken), cancellationToken);

    // Synchronous for callers already confined to a native worker; never nests scheduler slots.
    internal static byte[] ReadMetadataFile(WindowsPath path, int maximumBytes, bool requireSingleLink, CancellationToken cancellationToken)
    {
        if (maximumBytes is < 1 or > 4 * 1024 * 1024) throw new ArgumentOutOfRangeException(nameof(maximumBytes));
        cancellationToken.ThrowIfCancellationRequested();
        using var pinned = PinPath(path, readFinalData: true);
        var before = ReadEntry(path, pinned.Final);
        if (before.Kind != EntryKind.File || requireSingleLink && before.LinkCount != 1)
            throw new ShouException("unsafe_path", "Choose a regular metadata file without reparse points or cloud placeholders.");
        if (before.LogicalBytes < 0 || before.LogicalBytes > maximumBytes)
            throw new ShouException("resource_limit", "The metadata file exceeds its read limit.");
        var bytes = new byte[checked((int)before.LogicalBytes)];
        var offset = 0;
        while (offset < bytes.Length)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var read = RandomAccess.Read(pinned.Final, bytes.AsSpan(offset, Math.Min(16_384, bytes.Length - offset)), offset);
            if (read == 0) throw new ShouException("source_changed", "The metadata file changed while it was being read.");
            offset += read;
        }
        cancellationToken.ThrowIfCancellationRequested();
        if (ReadEntry(path, pinned.Final) != before)
            throw new ShouException("source_changed", "The metadata file changed while it was being read.");
        return bytes;
    }

    public ValueTask<FileEntry> InspectAsync(WindowsPath path, CancellationToken cancellationToken) =>
        NativeOperationScheduler.RunAsync(() =>
        {
            using var pinned = PinPath(path);
            return ReadEntry(path, pinned.Final);
        }, cancellationToken);

    public async IAsyncEnumerable<DirectoryReadItem> ReadDirectoryAsync(WindowsPath directory,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        using var stopped = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var token = stopped.Token;
        var channel = Channel.CreateBounded<DirectoryReadItem>(new BoundedChannelOptions(128)
        {
            SingleWriter = true, SingleReader = true, FullMode = BoundedChannelFullMode.Wait
        });
        await NativeOperationScheduler.Slots.WaitAsync(token).ConfigureAwait(false);
        var producer = Task.Run(() =>
        {
            try
            {
                using var pinned = PinPath(directory, finalAccess: NativeMethods.ReadData);
                var root = ReadEntry(directory, pinned.Final);
                if (root.Kind != EntryKind.Directory)
                    throw new ShouException("unsupported_location", "The selected object is not an accessible directory.");
                NativeDirectoryReader.Read(pinned.Final, root.IsCaseSensitive, 1_000_000, token.ThrowIfCancellationRequested, name =>
                {
                    var path = directory.Append(name);
                    DirectoryReadItem item;
                    try
                    {
                        using var handle = NativeFileHandles.OpenChild(pinned.Final, path, root.IsCaseSensitive, directory: false);
                        item = DirectoryReadItem.Found(ReadEntry(path, handle));
                    }
                    catch (ShouException error) { item = DirectoryReadItem.Unavailable(path, error.Code); }
                    channel.Writer.WriteAsync(item, token).AsTask().GetAwaiter().GetResult();
                });
                if (ReadEntry(directory, pinned.Final) != root)
                    throw new ShouException("directory_changed", "The workspace case or root metadata changed.");
                channel.Writer.TryComplete();
            }
            catch (Exception error) { channel.Writer.TryComplete(error); }
            finally { NativeOperationScheduler.Slots.Release(); }
        }, CancellationToken.None);
        NativeOperationScheduler.Observe(producer);
        var completedRead = false;
        try
        {
            await foreach (var entry in channel.Reader.ReadAllAsync(token).ConfigureAwait(false)) yield return entry;
            completedRead = true;
        }
        finally
        {
            stopped.Cancel();
            // A completed scan hands off to mutation only after the producer has closed its read handles.
            if (completedRead) await producer.ConfigureAwait(false);
        }
    }

    internal static PinnedPath PinPath(WindowsPath path, bool readFinalData = false, uint finalAccess = 0,
        bool allowFinalSharedWrites = false)
    {
        var drive = new DriveInfo(path.Value[..3]);
        if (drive.DriveType is not (DriveType.Fixed or DriveType.Removable) ||
            drive.DriveFormat is not ("NTFS" or "ReFS"))
            throw new ShouException("unsupported_filesystem", "Choose a local NTFS or ReFS directory.");
        var handles = new List<SafeFileHandle>();
        try
        {
            var current = WindowsPath.Parse(path.Value[..3]);
            var parts = path.IsVolumeRoot ? Array.Empty<string>() : path.Value[3..].Split('\\');
            if (parts.Length > 256) throw new ShouException("resource_limit", "The directory has too many ancestors to verify safely.");
            for (var index = -1; index < parts.Length; index++)
            {
                if (index >= 0) current = current.Append(parts[index]);
                var handle = Open(current, readFinalData && index == parts.Length - 1, index == parts.Length - 1 ? finalAccess : 0,
                    allowFinalSharedWrites && index == parts.Length - 1);
                handles.Add(handle);
                var basic = BasicInfo(handle);
                if (index < parts.Length - 1 && ((basic.Attributes & NativeMethods.ReparseAttribute) != 0 ||
                    (basic.Attributes & NativeMethods.DirectoryAttribute) == 0))
                    throw new ShouException("unsafe_path", "A directory ancestor is a reparse point or is unavailable.");
            }
            return new PinnedPath(handles);
        }
        catch
        {
            foreach (var handle in handles) handle.Dispose();
            throw;
        }
    }

    private static SafeFileHandle Open(WindowsPath path, bool readData = false, uint additionalAccess = 0, bool allowSharedWrites = false)
    {
        var handle = NativeMethods.CreateFile(Extended(path), NativeMethods.ReadAttributes | NativeMethods.ReadControl | (readData ? NativeMethods.ReadData : 0) | additionalAccess,
            NativeMethods.ShareRead | (allowSharedWrites ? NativeMethods.ShareWrite : 0), 0, NativeMethods.OpenExisting,
            NativeMethods.OpenReparsePoint | NativeMethods.BackupSemantics | NativeMethods.OpenNoRecall, 0);
        if (!handle.IsInvalid) return handle;
        var error = Marshal.GetLastPInvokeError();
        handle.Dispose();
        throw NativeError(error);
    }

    private static NativeMethods.FileBasicInfo BasicInfo(SafeFileHandle handle)
    {
        if (!NativeMethods.GetBasicInfo(handle, 0, out var basic, (uint)Marshal.SizeOf<NativeMethods.FileBasicInfo>()))
            throw NativeError(Marshal.GetLastPInvokeError());
        return basic;
    }

    internal static unsafe FileEntry ReadEntry(WindowsPath path, SafeFileHandle handle)
    {
        var basic = BasicInfo(handle);
        if (!NativeMethods.GetStandardInfo(handle, 1, out var standard, (uint)Marshal.SizeOf<NativeMethods.FileStandardInfo>()) ||
            !NativeMethods.GetIdInfo(handle, 18, out var id, (uint)Marshal.SizeOf<NativeMethods.FileIdInfo>()))
            throw NativeError(Marshal.GetLastPInvokeError());
        if (standard.DeletePending != 0)
            throw new ShouException("source_changed", "The filesystem object is pending removal.");
        var kind = (basic.Attributes & NativeMethods.ReparseAttribute) != 0 ? EntryKind.ReparsePoint :
            (basic.Attributes & NativeMethods.OfflineAttribute) != 0 ? EntryKind.Unsupported :
            standard.Directory != 0 ? EntryKind.Directory : EntryKind.File;
        var sensitive = false;
        if (kind == EntryKind.Directory)
        {
            if (!NativeMethods.GetCaseInfo(handle, 23, out var info, (uint)Marshal.SizeOf<NativeMethods.FileCaseInfo>()))
                throw NativeError(Marshal.GetLastPInvokeError());
            sensitive = (info.Flags & 1) != 0;
        }
        var identity = new FileIdentity(id.VolumeSerialNumber, Convert.ToHexString(new ReadOnlySpan<byte>(id.Id, 16)), OwnerSid(handle));
        try
        {
            return new(path, identity, kind, standard.Directory != 0 ? 0 : standard.EndOfFile,
                standard.AllocationSize, DateTimeOffset.FromFileTime(basic.LastWriteTime).ToUniversalTime(),
                DateTimeOffset.FromFileTime(basic.ChangeTime).ToUniversalTime(), standard.NumberOfLinks, sensitive);
        }
        catch (ArgumentOutOfRangeException error) { throw new ShouException("unsupported_metadata", "The native timestamps cannot be represented.", error); }
    }

    private static string OwnerSid(SafeFileHandle handle)
    {
        var result = NativeMethods.GetSecurityInfo(handle, 1, 1, out var owner, 0, 0, 0, out var descriptor);
        if (result != 0) throw NativeError((int)result);
        try
        {
            if (!NativeMethods.ConvertSidToString(owner, out var text)) throw NativeError(Marshal.GetLastPInvokeError());
            try { return Marshal.PtrToStringUni(text) ?? throw new ShouException("unsupported_metadata", "The owner SID could not be read."); }
            finally { NativeMethods.LocalFree(text); }
        }
        finally { NativeMethods.LocalFree(descriptor); }
    }

    internal static ShouException NativeError(int error) => new(error switch
    {
        2 or 3 => "not_found",
        5 => "permission_denied",
        32 or 33 => "active_or_inaccessible",
        50 => "unsupported_filesystem",
        _ => "read_failed"
    }, "Windows could not verify the selected filesystem object.", new Win32Exception(error));

    internal static string Extended(WindowsPath path) => @"\\?\" + path.Value;

    internal sealed class PinnedPath(List<SafeFileHandle> handles) : IDisposable
    {
        public SafeFileHandle Final => handles[^1];
        public void Dispose()
        {
            for (var index = handles.Count - 1; index >= 0; index--) handles[index].Dispose();
        }
    }
}
