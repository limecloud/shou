using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.Platform.Tests;

public sealed class AgentSkillInstallationTests
{
    private static string TemporaryDirectory()
    {
        var path = Path.GetTempPath();
        return OperatingSystem.IsMacOS() && path.StartsWith("/var/", StringComparison.Ordinal) ? "/private" + path : path;
    }
    [Theory]
    [InlineData(BundledAgentSkills.CleanupName)]
    [InlineData(BundledAgentSkills.DefaultName)]
    public void InstallsExportsAndPreservesLocalEdits(string skill)
    {
        var root = Path.Combine(TemporaryDirectory(), "shou-skill-fixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var installed = AgentSkillInstallation.Install("codex", skill, root);
            Assert.Equal("installed", installed.State);
            foreach (var (file, content) in BundledAgentSkills.Files(skill))
                Assert.Equal(content, File.ReadAllText(Path.Combine(installed.Directory, file)));
            Assert.Equal("already_current", AgentSkillInstallation.Install("codex", skill, root).State);
            var entry = Path.Combine(installed.Directory, "SKILL.md");
            File.WriteAllText(entry, "generated local edit");
            Assert.Equal("version_conflict", Assert.Throws<ShouException>(() => AgentSkillInstallation.Install("codex", skill, root)).Code);
            Assert.Equal("generated local edit", File.ReadAllText(entry));
            var manifest = Path.Combine(installed.Directory, ".shou-skill-manifest.json");
            var previous = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllBytes(manifest))!;
            var files = JsonSerializer.Deserialize<Dictionary<string, string>>(previous["files"].GetRawText())!;
            files["SKILL.md"] = "sha256:" + Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(entry)));
            File.WriteAllBytes(manifest, JsonSerializer.SerializeToUtf8Bytes(new { skill, files }));
            var updated = AgentSkillInstallation.Install("codex", skill, root);
            Assert.Equal("updated", updated.State);
            Assert.Equal("generated local edit", File.ReadAllText(Path.Combine(updated.BackupDirectory!, "SKILL.md")));
            var zip = Path.Combine(root, "assistant.zip");
            AgentSkillInstallation.Export(zip, skill);
            using var archive = ZipFile.OpenRead(zip);
            Assert.Equal(BundledAgentSkills.Files(skill).Keys.Select(key => skill + "/" + key).Order(), archive.Entries.Select(entry => entry.FullName).Order());
            Assert.Throws<IOException>(() => AgentSkillInstallation.Export(zip, skill));
            Assert.Throws<ShouException>(() => BundledAgentSkills.Read(skill, "../SKILL.md"));
            Assert.Throws<ShouException>(() => AgentSkillInstallation.Install("codex", skill, "relative"));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void RejectsLinkedDestinationWithoutChangingItsContents()
    {
        var root = Path.Combine(TemporaryDirectory(), "shou-skill-link-fixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var external = Directory.CreateDirectory(Path.Combine(root, "external")).FullName;
            var linked = Path.Combine(root, "linked");
            try { Directory.CreateSymbolicLink(linked, external); }
            catch (UnauthorizedAccessException) { return; } // Windows requires Developer Mode or link privilege.
            Assert.Throws<ShouException>(() => AgentSkillInstallation.Install("codex", BundledAgentSkills.CleanupName, linked));
            Assert.Empty(Directory.EnumerateFileSystemEntries(external));
        }
        finally { Directory.Delete(root, true); }
    }
}
