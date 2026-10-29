using System.Buffers.Binary;
using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Reads plain local Shell Link data. Never invokes a shell, Resolve, target executable or search provider.</summary>
public sealed class WindowsApplicationShortcuts : IApplicationShortcutInspector
{
    public ImmutableArray<WindowsPath> Roots { get; } = new[] { Environment.SpecialFolder.Programs, Environment.SpecialFolder.DesktopDirectory }
        .Select(Environment.GetFolderPath).Where(value => !string.IsNullOrWhiteSpace(value)).Select(WindowsPath.Parse).Distinct().ToImmutableArray();

    public Task<ApplicationShortcutReview> InspectAsync(WindowsPath path, CancellationToken token) => NativeOperationScheduler.RunAsync(() => Inspect(path, token), token).AsTask();

    private ApplicationShortcutReview Inspect(WindowsPath path, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (!NativeWindowsSupport.IsSupported || !Roots.Any(root => path.IsWithin(root, includeRoot: false)) ||
            !path.Name.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase) || path.Parent is not { } parent) throw Unsupported();
        using var actor = WindowsIdentity.GetCurrent();
        using var pinned = WindowsFileSystem.PinPath(path);
        using var pinnedParent = WindowsFileSystem.PinPath(parent);
        var file = WindowsFileSystem.ReadEntry(path, pinned.Final);
        var directory = WindowsFileSystem.ReadEntry(parent, pinnedParent.Final);
        if (file.Kind != EntryKind.File || file.LinkCount != 1 || file.LogicalBytes is < 76 or > 1_048_576 ||
            file.Identity.OwnerSid != actor.User?.Value || directory.Identity.OwnerSid != actor.User?.Value || directory.Kind != EntryKind.Directory) throw Unsupported();
        var bytes = new byte[checked((int)file.LogicalBytes)];
        var offset = 0;
        while (offset < bytes.Length)
        {
            token.ThrowIfCancellationRequested();
            var read = RandomAccess.Read(pinned.Final, bytes.AsSpan(offset), offset);
            if (read == 0) throw Unsupported();
            offset += read;
        }
        var target = ReadLocalTarget(bytes);
        token.ThrowIfCancellationRequested();
        try
        {
            using var existing = WindowsFileSystem.PinPath(target);
            throw new ShouException("shortcut_target_present", "The shortcut target exists; this shortcut is kept.");
        }
        catch (ShouException error) when (error.Code == "not_found") { }
        if (WindowsFileSystem.ReadEntry(path, pinned.Final) != file || WindowsFileSystem.ReadEntry(parent, pinnedParent.Final).Identity != directory.Identity)
            throw new ShouException("plan_stale", "The shortcut changed. Check this application again.");
        return new(file, directory, target, "sha256:" + Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), DateTimeOffset.UtcNow);
    }

    internal static WindowsPath ReadLocalTarget(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length is < 80 or > 1_048_576 || U32(bytes, 0) != 76 ||
            !bytes.Slice(4, 16).SequenceEqual(new byte[] { 1, 20, 2, 0, 0, 0, 0, 0, 192, 0, 0, 0, 0, 0, 0, 70 })) throw Unsupported();
        var flags = U32(bytes, 20);
        // PIDL, relative, advertised, environment and tracking targets remain read-only.
        if ((flags & 2) == 0 || (flags & ~0xf6u) != 0) throw Unsupported();
        var rawSize = U32(bytes, 76);
        if (rawSize < 28 || rawSize > bytes.Length - 76) throw Unsupported();
        var size = (int)rawSize;
        var info = bytes.Slice(76, size);
        var header = U32(info, 4);
        if (header is not (28 or 36) || size < header || U32(info, 8) != 1 || U32(info, 20) != 0) throw Unsupported();
        var volumeOffset = U32(info, 12);
        if (volumeOffset < header || volumeOffset > size - 16) throw Unsupported();
        var volume = info[(int)volumeOffset..];
        var volumeSize = U32(volume, 0);
        if (volumeSize < 17 || volumeSize > volume.Length || U32(volume, 4) != 3 || U32(volume, 12) != 16) throw Unsupported();
        _ = ReadString(volume[..(int)volumeSize], 16, 16, false);
        var unicode = header == 36 && U32(info, 28) != 0 && U32(info, 32) != 0;
        var target = ReadString(info, U32(info, unicode ? 28 : 16), header, unicode);
        var suffix = ReadString(info, U32(info, unicode ? 32 : 24), header, unicode);
        // Conflicting ANSI/Unicode targets are ambiguous; no shell fallback is allowed.
        if (unicode && (target != ReadString(info, U32(info, 16), header, false) || suffix != ReadString(info, U32(info, 24), header, false))) throw Unsupported();
        if (string.IsNullOrEmpty(suffix) || !target.EndsWith(suffix, StringComparison.Ordinal) ||
            target.Contains('%') || target.Contains('/') || target.Length < 4 || target[1] != ':' || target[2] != '\\') throw Unsupported();
        var result = WindowsPath.Parse(target);
        if (!result.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && !result.Name.EndsWith(".com", StringComparison.OrdinalIgnoreCase)) throw Unsupported();
        var cursor = 76 + size;
        foreach (var bit in new uint[] { 4, 16, 32, 64 })
        {
            if ((flags & bit) == 0) continue;
            if (cursor > bytes.Length - 2) throw Unsupported();
            var length = BinaryPrimitives.ReadUInt16LittleEndian(bytes.Slice(cursor, 2));
            cursor = checked(cursor + 2 + length * ((flags & 128) != 0 ? 2 : 1));
            if (cursor > bytes.Length) throw Unsupported();
        }
        if (cursor != bytes.Length - 4 || U32(bytes, cursor) != 0) throw Unsupported();
        return result;
    }
    private static uint U32(ReadOnlySpan<byte> bytes, int offset) => offset >= 0 && offset <= bytes.Length - 4
        ? BinaryPrimitives.ReadUInt32LittleEndian(bytes.Slice(offset, 4)) : throw Unsupported();
    private static string ReadString(ReadOnlySpan<byte> bytes, uint offset, uint header, bool unicode)
    {
        if (offset < header || offset >= bytes.Length) throw Unsupported();
        var start = checked((int)offset);
        for (var cursor = start; cursor < bytes.Length - (unicode ? 1 : 0); cursor += unicode ? 2 : 1)
        {
            if (bytes[cursor] != 0 || unicode && bytes[cursor + 1] != 0) continue;
            var value = bytes.Slice(start, cursor - start);
            if (!unicode && value.ContainsAnyInRange((byte)128, byte.MaxValue)) throw Unsupported();
            try { return unicode ? new UnicodeEncoding(false, false, true).GetString(value) : Encoding.ASCII.GetString(value); }
            catch (DecoderFallbackException) { throw Unsupported(); }
        }
        throw Unsupported();
    }
    private static ShouException Unsupported() => new("shortcut_target_unverified", "This shortcut target cannot be verified without resolving it; the shortcut is kept.");
}
