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

    public static string Digest<T>(T value)
    {
        using var stream = new DigestStream();
        JsonSerializer.Serialize(stream, value, ContractJson.Options);
        return stream.Digest();
    }

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

    private sealed class DigestStream : Stream
    {
        private readonly IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) => hash.AppendData(buffer, offset, count);
        public override void Write(ReadOnlySpan<byte> buffer) => hash.AppendData(buffer);
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        internal string Digest() => "sha256:" + Convert.ToHexStringLower(hash.GetHashAndReset());
        protected override void Dispose(bool disposing) { if (disposing) hash.Dispose(); base.Dispose(disposing); }
    }
}
