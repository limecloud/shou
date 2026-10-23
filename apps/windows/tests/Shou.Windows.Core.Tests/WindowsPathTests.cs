using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class WindowsPathTests
{
    [Theory]
    [InlineData("relative/folder")]
    [InlineData("C:relative")]
    [InlineData(@"\\server\share\folder")]
    [InlineData(@"\\?\C:\folder")]
    [InlineData(@"\\.\PhysicalDrive0")]
    [InlineData(@"\??\C:\folder")]
    [InlineData(@"C:\folder\..\secret")]
    [InlineData(@"C:\folder\.\secret")]
    [InlineData(@"C:\folder\\secret")]
    [InlineData(@"C:\folder\secret:stream")]
    [InlineData(@"C:\folder\secret.")]
    [InlineData("C:\\folder\\secret ")]
    [InlineData("C:\\folder\\line\nbreak")]
    [InlineData(@"C:\folder\NUL.txt")]
    [InlineData(@"C:\folder\NUL .txt")]
    [InlineData(@"C:\folder\COM1 .log")]
    [InlineData(@"C:\folder\com1.log")]
    [InlineData(@"C:\folder\LPT³.txt")]
    [InlineData(@"C:\folder\CONOUT$")]
    [InlineData(@"C:\folder\*.txt")]
    public void RejectsAmbiguousAndNonlocalPaths(string path) =>
        Assert.Equal("invalid_path", Assert.Throws<ShouException>(() => WindowsPath.Parse(path)).Code);

    [Fact]
    public void ParsesWindowsPathsIndependentlyOfHost()
    {
        var root = WindowsPath.Parse("c:/Users/开发者/项目/");
        Assert.Equal(@"C:\Users\开发者\项目", root.Value);
        Assert.Equal("项目", root.Name);
        Assert.Equal(@"C:\Users\开发者", root.Parent!.Value);
        Assert.Equal("build/output.bin", root.Append("build/output.bin").RelativeTo(root));
        Assert.True(WindowsPath.Parse(@"C:\").IsVolumeRoot);
        Assert.Null(WindowsPath.Parse(@"C:\").Parent);
        Assert.Equal(@"C:\", WindowsPath.Parse(@"C:\file").Parent!.Value);
    }

    [Fact]
    public void ContainmentUsesComponentBoundariesAndExplicitCaseSemantics()
    {
        var root = WindowsPath.Parse(@"C:\Work");
        Assert.True(WindowsPath.Parse(@"c:\work\child").IsWithin(root));
        Assert.False(WindowsPath.Parse(@"C:\work\child").IsWithin(root, caseSensitive: true));
        Assert.False(WindowsPath.Parse(@"C:\Work-other\child").IsWithin(root));
        Assert.False(WindowsPath.Parse(@"D:\Work\child").IsWithin(root));
        Assert.False(root.IsWithin(root, includeRoot: false));
        Assert.True(root.IsWithin(WindowsPath.Parse(@"C:\")));
    }

    [Theory]
    [InlineData("../escape")]
    [InlineData("/absolute")]
    [InlineData("folder//file")]
    [InlineData(@"folder\file")]
    [InlineData("file:stream")]
    [InlineData("CON")]
    public void AppendedPathsCannotEscapeOrIntroduceDeviceNames(string relative) =>
        Assert.Throws<ShouException>(() => WindowsPath.Parse(@"C:\Work").Append(relative));

    [Fact]
    public void BoundsComponentLength() => Assert.Throws<ShouException>(() => WindowsPath.Parse("C:\\" + new string('x', 256)));

    [Fact]
    public void RejectsIllFormedUtf16WithoutNormalizingValidUnicode()
    {
        foreach (var suffix in new[] { new string((char)0xd800, 1), new string((char)0xdc00, 1), "a" + (char)0xd800 + "b" })
            Assert.Throws<ShouException>(() => WindowsPath.Parse("C:/Work/" + suffix));
        Assert.NotEqual(WindowsPath.Parse("C:/Work/café"), WindowsPath.Parse("C:/Work/cafe\u0301"));
        Assert.Equal("📁", WindowsPath.Parse("C:/Work/📁").Name);
    }
}
