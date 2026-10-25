using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Reads complete SHA-1 index v2/v3 entries without executing Git or repository configuration.</summary>
internal static class GitIndexReader
{
    internal const int MaximumBytes = 4 * 1024 * 1024;
    private static readonly UTF8Encoding Utf8 = new(false, true);

    internal static bool HasTrackedContent(ReadOnlySpan<byte> bytes, string relativeTarget, CancellationToken token = default)
    {
        WindowsPath.ValidateRelative(relativeTarget);
        token.ThrowIfCancellationRequested();
        if (bytes.Length is < 32 or > MaximumBytes || !bytes[..4].SequenceEqual("DIRC"u8) ||
            !CryptographicOperations.FixedTimeEquals(SHA1.HashData(bytes[..^20]), bytes[^20..])) throw Unavailable();
        var version = BinaryPrimitives.ReadUInt32BigEndian(bytes[4..]);
        var count = BinaryPrimitives.ReadUInt32BigEndian(bytes[8..]);
        if (version is not (2 or 3) || count > 50_000) throw Unavailable();
        var end = bytes.Length - 20;
        var offset = 12;
        var tracked = false;
        for (var entry = 0u; entry < count; entry++)
        {
            token.ThrowIfCancellationRequested();
            var start = offset;
            if (end - offset < 63) throw Unavailable();
            var mode = BinaryPrimitives.ReadUInt32BigEndian(bytes[(offset + 24)..]);
            if (mode is not (0x81a4 or 0x81ed or 0xa000 or 0xe000)) throw Unavailable();
            var flags = BinaryPrimitives.ReadUInt16BigEndian(bytes[(offset + 60)..]);
            offset += 62;
            if ((flags & 0x4000) != 0)
            {
                if (version != 3 || end - offset < 3 || (BinaryPrimitives.ReadUInt16BigEndian(bytes[offset..]) & ~0x6000) != 0) throw Unavailable();
                offset += 2;
            }
            var length = bytes[offset..end].IndexOf((byte)0);
            if (length is < 1 or > 32_767 || (flags & 0xfff) != Math.Min(length, 0xfff)) throw Unavailable();
            string path;
            try { path = Utf8.GetString(bytes.Slice(offset, length)); WindowsPath.ValidateRelative(path); }
            catch (Exception error) when (error is DecoderFallbackException or ShouException or ArgumentException) { throw Unavailable(); }
            // Conservative case folding also protects repositories hosted in case-sensitive directories.
            tracked |= path.Equals(relativeTarget, StringComparison.OrdinalIgnoreCase) ||
                path.StartsWith(relativeTarget + "/", StringComparison.OrdinalIgnoreCase) ||
                relativeTarget.StartsWith(path + "/", StringComparison.OrdinalIgnoreCase);
            var size = checked(offset - start + length + 1);
            var padding = (8 - size % 8) % 8;
            offset += length + 1;
            if (end - offset < padding || bytes.Slice(offset, padding).IndexOfAnyExcept((byte)0) >= 0) throw Unavailable();
            offset += padding;
        }
        while (offset < end)
        {
            token.ThrowIfCancellationRequested();
            if (end - offset < 8 || bytes[offset] is < (byte)'A' or > (byte)'Z') throw Unavailable();
            // Lowercase mandatory extensions (including split and sparse indexes) change index semantics and are refused.
            var length = BinaryPrimitives.ReadUInt32BigEndian(bytes[(offset + 4)..]);
            if (length > end - offset - 8) throw Unavailable();
            offset += 8 + (int)length;
        }
        return tracked;
    }

    internal static ShouException Unavailable() => new("artifact_evidence_unavailable", "The repository tracking evidence is unavailable or uses an unsupported index format.");
}
