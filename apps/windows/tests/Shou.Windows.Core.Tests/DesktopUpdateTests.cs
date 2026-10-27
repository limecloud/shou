using System.Text;
using System.Text.Json;

namespace Shou.Windows.Core.Tests;

public sealed class DesktopUpdateTests
{
    private static byte[] Release(string tag = "v0.18.0", string architecture = "x64", string? download = null,
        bool draft = false, bool prerelease = false, string? page = null) => JsonSerializer.SerializeToUtf8Bytes(new
        {
            tag_name = tag, draft, prerelease, html_url = page ?? "https://github.com/limecloud/shou/releases/tag/" + tag,
            body = "更新说明 <script>plain text</script>", assets = new[] { new { name = $"Shou-{tag[1..]}-windows-{architecture}.zip",
                browser_download_url = download ?? $"https://github.com/limecloud/shou/releases/download/{tag}/Shou-{tag[1..]}-windows-{architecture}.zip", size = 1234 } }
        });

    [Theory]
    [InlineData("0.17.0", true)]
    [InlineData("0.9.0", true)]
    [InlineData("0.18.0", false)]
    [InlineData("0.19.0", false)]
    public void ComparesStableNumericVersionsWithoutOfferingDowngrades(string current, bool newer)
    {
        var result = DesktopUpdate.Parse(Release(), current, "x64");
        Assert.Equal(newer, result.IsNewer);
        Assert.Equal("0.18.0", result.Version);
        Assert.Contains("<script>plain text</script>", result.Notes);
    }

    [Fact]
    public void SelectsOnlyTheExactArchitectureAndRepositoryAsset()
    {
        Assert.EndsWith("arm64.zip", DesktopUpdate.Parse(Release(architecture: "arm64"), "0.17.0", "arm64").DownloadUrl.AbsoluteUri);
        Assert.Throws<ShouException>(() => DesktopUpdate.Parse(Release(), "0.17.0", "arm64"));
        Assert.Throws<ShouException>(() => DesktopUpdate.Parse(Release(download: "https://evil.example/update.zip"), "0.17.0", "x64"));
        Assert.Throws<ShouException>(() => DesktopUpdate.Parse(Release(page: "https://github.com/other/shou/releases/tag/v0.18.0"), "0.17.0", "x64"));
    }

    [Fact]
    public void RejectsPreviewMalformedOversizeAndUnsupportedMetadata()
    {
        foreach (var bytes in new[] { Release(draft: true), Release(prerelease: true), Release("v0.18.0-beta"), Release("v00.18.0"),
            Encoding.UTF8.GetBytes("{}"), new byte[DesktopUpdate.MaximumMetadataBytes + 1] })
            Assert.Throws<ShouException>(() => DesktopUpdate.Parse(bytes, "0.17.0", "x64"));
        Assert.Throws<ShouException>(() => DesktopUpdate.Parse(Release(), "development", "x64"));
        Assert.Throws<ShouException>(() => DesktopUpdate.Parse(Release(), "0.17.0", "x86"));
    }
}
