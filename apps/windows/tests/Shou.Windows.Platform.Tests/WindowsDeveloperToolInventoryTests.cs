using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsDeveloperToolInventoryTests
{
    [Fact]
    public void NpmWrappersUsePackageMetadataAndMalformedMetadataStaysUnverified()
    {
        var root = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "shou-generated-npm-" + Guid.NewGuid().ToString("N"));
        var package = System.IO.Path.Combine(root, "node_modules", "@openai", "codex");
        Directory.CreateDirectory(package);
        try
        {
            var launcher = System.IO.Path.Combine(root, "codex.cmd");
            File.WriteAllText(launcher, "exit /b 73");
            var manifest = System.IO.Path.Combine(package, "package.json");
            var tool = new DeveloperToolDefinition("codex", "Codex", "ai-coding", "https://github.com/openai/codex", [], ["codex"], ["@openai/codex"]);
            File.WriteAllText(manifest, """{"name":"@openai/codex","version":"1.2.3"}""");
            var observed = WindowsDeveloperToolInventory.Observe(launcher, tool);
            Assert.NotNull(observed); Assert.Equal("Node package", observed.Source); Assert.Equal("1.2.3", observed.Version);
            Assert.Equal(package, observed.Path); Assert.Equal(new[] { launcher }, observed.LaunchPaths.ToArray());
            foreach (var malformed in new[] { "[]", "null", "{\"name\":17}", "{\"name\":\"@openai/codex\",\"version\":[]}", new string(' ', 262_145) })
            {
                File.WriteAllText(manifest, malformed);
                var unverified = WindowsDeveloperToolInventory.Observe(launcher, tool);
                Assert.NotNull(unverified); Assert.Null(unverified.Version); Assert.Equal("detected", unverified.Status);
            }
        }
        finally { Directory.Delete(root, true); }
    }
}
