using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class GitIndexReaderTests
{
    internal static byte[] Index(string[] paths, uint version = 2, string? extension = null, bool extended = false)
    {
        using var output = new MemoryStream();
        output.Write("DIRC"u8); Write32(version); Write32((uint)paths.Length);
        foreach (var path in paths)
        {
            var start = output.Position;
            output.Write(new byte[24]); Write32(0x81a4); output.Write(new byte[32]);
            var bytes = Encoding.UTF8.GetBytes(path);
            var flags = (ushort)(Math.Min(bytes.Length, 0xfff) | (extended ? 0x4000 : 0));
            output.WriteByte((byte)(flags >> 8)); output.WriteByte((byte)flags);
            if (extended) output.Write([0x40, 0x00]); // skip-worktree still represents tracked content.
            output.Write(bytes); output.WriteByte(0);
            while ((output.Position - start) % 8 != 0) output.WriteByte(0);
        }
        if (extension is not null) { output.Write(Encoding.ASCII.GetBytes(extension)); Write32(0); }
        return WithChecksum(output.ToArray());
        void Write32(uint number)
        { Span<byte> value = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(value, number); output.Write(value); }
    }
    internal static byte[] WithChecksum(byte[] body) => [..body, ..SHA1.HashData(body)];

    [Theory]
    [InlineData("project/target/cache.bin", true)]
    [InlineData("PROJECT/TARGET/generated.rs", true)]
    [InlineData("project/target", true)]
    [InlineData("project", true)]
    [InlineData("project/target-other/source.rs", false)]
    [InlineData("project/src/main.rs", false)]
    [InlineData("another/target/cache.bin", false)]
    public void UsesComponentBoundariesAndConservativeCaseFolding(string path, bool tracked) =>
        Assert.Equal(tracked, GitIndexReader.HasTrackedContent(Index([path]), "project/target"));

    [Fact]
    public void UnicodeOptionalCacheExtensionsAndVersionThreeRemainComplete()
    {
        Assert.True(GitIndexReader.HasTrackedContent(Index(["项目/target/生成.rs"], 3, "TREE", true), "项目/target"));
        Assert.False(GitIndexReader.HasTrackedContent(Index([], 2, "TREE"), "项目/target"));
    }

    [Theory]
    [InlineData("link")]
    [InlineData("sdir")]
    [InlineData("abcd")]
    public void MandatoryExtensionsCannotBeIgnored(string extension) =>
        Assert.Throws<ShouException>(() => GitIndexReader.HasTrackedContent(Index([], extension: extension), "target"));

    [Theory]
    [InlineData(1)]
    [InlineData(4)]
    [InlineData(255)]
    public void UnsupportedIndexVersionsDoNotProveUntrackedContent(uint version) =>
        Assert.Throws<ShouException>(() => GitIndexReader.HasTrackedContent(Index([], version), "target"));

    [Theory]
    [InlineData("../target/file.rs")]
    [InlineData("/target/file.rs")]
    [InlineData("target/file:stream")]
    [InlineData("target/CON")]
    [InlineData("target\\file.rs")]
    public void UnsafeIndexNamesFailTheEntireObservation(string path) =>
        Assert.Throws<ShouException>(() => GitIndexReader.HasTrackedContent(Index([path]), "target"));

    [Fact]
    public void ChecksumTruncationCountAndEntryFlagsCannotHideLaterTrackedEntries()
    {
        var valid = Index(["unrelated/file.bin", "target/tracked.rs"]);
        var corrupt = valid.ToArray(); corrupt[30] ^= 1;
        Assert.Throws<ShouException>(() => GitIndexReader.HasTrackedContent(corrupt, "target"));
        Assert.Throws<ShouException>(() => GitIndexReader.HasTrackedContent(valid[..^1], "target"));
        var body = valid[..^20]; BinaryPrimitives.WriteUInt32BigEndian(body.AsSpan(8), 3);
        Assert.Throws<ShouException>(() => GitIndexReader.HasTrackedContent(WithChecksum(body), "target"));
        Assert.Throws<ShouException>(() => GitIndexReader.HasTrackedContent(Index(["target/file.rs"], 2, extended: true), "target"));
        body = Index(["target/tracked.rs"])[..^20]; body[74] = 0xff; // Invalid UTF-8 in the first path.
        Assert.Throws<ShouException>(() => GitIndexReader.HasTrackedContent(WithChecksum(body), "target"));
    }

    [Fact]
    public void CancellationAndSizeLimitsRemainFailures()
    {
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => GitIndexReader.HasTrackedContent(Index([]), "target", cancelled.Token));
        Assert.Throws<ShouException>(() => GitIndexReader.HasTrackedContent(new byte[GitIndexReader.MaximumBytes + 1], "target"));
    }
}
