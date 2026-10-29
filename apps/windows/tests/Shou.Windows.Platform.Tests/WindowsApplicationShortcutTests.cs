using System.Buffers.Binary;
using System.Text;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsApplicationShortcutTests
{
    private static byte[] Link(string target)
    {
        var path = Encoding.Unicode.GetBytes(target + "\0");
        var suffix = Encoding.Unicode.GetBytes("Generated.exe\0");
        var ansiPath = Encoding.ASCII.GetBytes(target + "\0");
        var ansiSuffix = Encoding.ASCII.GetBytes("Generated.exe\0");
        var pathOffset = 36 + 17 + ansiPath.Length + ansiSuffix.Length;
        var bytes = new byte[76 + pathOffset + path.Length + suffix.Length + 4];
        void U32(int offset, uint value) => BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(offset, 4), value);
        U32(0, 76);
        new byte[] { 1, 20, 2, 0, 0, 0, 0, 0, 192, 0, 0, 0, 0, 0, 0, 70 }.CopyTo(bytes, 4);
        U32(20, 130); U32(76, (uint)(pathOffset + path.Length + suffix.Length)); U32(80, 36); U32(84, 1);
        U32(88, 36); U32(92, 53); U32(100, (uint)(53 + ansiPath.Length));
        U32(104, (uint)pathOffset); U32(108, (uint)(pathOffset + path.Length));
        U32(112, 17); U32(116, 3); U32(124, 16);
        ansiPath.CopyTo(bytes, 129); ansiSuffix.CopyTo(bytes, 129 + ansiPath.Length);
        path.CopyTo(bytes, 76 + pathOffset); suffix.CopyTo(bytes, 76 + pathOffset + path.Length);
        return bytes;
    }
    [Fact]
    public void PlainLocalTargetIsParsedWithoutShellResolutionAndMalformedOrExpandedTargetsAreRejected()
    {
        var bytes = Link("C:\\Generated\\Generated.exe");
        Assert.Equal(WindowsPath.Parse("C:/Generated/Generated.exe"), WindowsApplicationShortcuts.ReadLocalTarget(bytes));
        foreach (var flags in new uint[] { 131, 138, 642, uint.MaxValue })
        {
            var changed = bytes.ToArray(); BinaryPrimitives.WriteUInt32LittleEndian(changed.AsSpan(20, 4), flags);
            Assert.Throws<ShouException>(() => WindowsApplicationShortcuts.ReadLocalTarget(changed));
        }
        Assert.Throws<ShouException>(() => WindowsApplicationShortcuts.ReadLocalTarget(Link("\\\\server\\share\\Generated.exe")));
        Assert.Throws<ShouException>(() => WindowsApplicationShortcuts.ReadLocalTarget(Link("C:\\%TEMP%\\Generated.exe")));
        var forged = bytes.ToArray(); BinaryPrimitives.WriteUInt32LittleEndian(forged.AsSpan(76, 4), uint.MaxValue);
        Assert.Throws<ShouException>(() => WindowsApplicationShortcuts.ReadLocalTarget(forged));
        for (var length = 0; length < bytes.Length; length++)
            Assert.Throws<ShouException>(() => WindowsApplicationShortcuts.ReadLocalTarget(bytes.AsSpan(0, length)));
    }
}
