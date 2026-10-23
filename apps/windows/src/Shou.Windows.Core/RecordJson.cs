using System.Security.Cryptography;
using System.Text.Json;

namespace Shou.Windows.Core;

internal static class RecordJson
{
    public static byte[] Encode<T>(T value, int maximumBytes)
    {
        using var stream = new BoundedStream(maximumBytes);
        JsonSerializer.Serialize(stream, value, ContractJson.Options);
        return stream.ToArray();
    }

    public static string Digest<T>(T value) => "sha256:" + Convert.ToHexStringLower(SHA256.HashData(Encode(value, 134_217_728)));

    public static bool IsDigest(string? value) => value is { Length: 71 } && value.StartsWith("sha256:", StringComparison.Ordinal) &&
        value[7..].All(character => char.IsAsciiDigit(character) || character is >= 'a' and <= 'f');

    private sealed class BoundedStream(int maximumBytes) : MemoryStream
    {
        public override void Write(byte[] buffer, int offset, int count) { Check(count); base.Write(buffer, offset, count); }
        public override void Write(ReadOnlySpan<byte> buffer) { Check(buffer.Length); base.Write(buffer); }
        public override void WriteByte(byte value) { Check(1); base.WriteByte(value); }
        private void Check(int count)
        {
            if (Position + count > maximumBytes) throw new ShouException("resource_limit", "The record exceeds its storage budget. Use a smaller selection.");
        }
    }
}
