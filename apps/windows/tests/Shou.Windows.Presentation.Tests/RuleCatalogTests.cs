using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed class RuleCatalogTests
{
    private static BuiltinRuleCatalog Catalog()
    {
        var validator = new RuleSchemaValidator(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Contracts/rule.schema.json")));
        byte[] Resource(string name) => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Catalog", name + ".json"));
        var home = WindowsPath.Parse("C:/Users/Generated");
        return new(validator, new(home, home.Append("AppData/Local"), home.Append("AppData/Roaming")),
            Resource("builtin-rules"), Resource("known-locations"), Resource("project-locations"));
    }

    [Fact]
    public void EmptyConfigurationCanBrowseAllBundledRulesWithoutGrantingEnablement()
    {
        var catalog = Catalog();
        var entries = RuleCatalog.Read(catalog, Configuration.Empty, null);
        Assert.Equal(catalog.Templates.Length, entries.Length);
        Assert.All(entries, entry => { Assert.True(entry.Builtin); Assert.False(entry.Applicable); Assert.False(entry.Enabled); });
        Assert.Empty(RuleCatalog.Read(catalog, Configuration.Empty, null, "personal"));
        Assert.NotEmpty(RuleCatalog.Read(catalog, Configuration.Empty, null, query: "node_modules"));
        Assert.All(catalog.Templates, template =>
        {
            var entry = entries.Single(value => value.Id == template.Id);
            var location = template.Location == "projects" ? "Developer Projects" :
                catalog.Locations.Single(value => value.Id == template.Location).Title;
            Assert.Equal(template.Limitation, entry.Limitation);
            Assert.Equal(location, entry.Location);
            Assert.Equal(template.RebuildNote, entry.Description);
        });
    }

    [Fact]
    public void CatalogUsesExactLocationApplicabilityAndDisabledPreferences()
    {
        var catalog = Catalog();
        var npm = catalog.Locations.Single(value => value.Id == "windows-npm");
        var workspace = new Workspace("ws_" + new string('1', 32), "generated-npm", npm.Path,
            new(1, new string('2', 32), "S-1-5-21-1000"), false, [], DateTimeOffset.UnixEpoch);
        var rule = Assert.Single(catalog.RulesFor(workspace));
        var configuration = Configuration.Empty with { Workspaces = [workspace], Bindings = [new(workspace.Id, rule.Id, rule.Version, rule.Digest, false)] };
        var entries = RuleCatalog.Read(catalog, configuration, workspace);
        Assert.Single(entries.Where(entry => entry.Applicable));
        Assert.False(entries.Single(entry => entry.Id == rule.Id).Enabled);
        Assert.All(entries.Where(entry => entry.Id != rule.Id), entry => Assert.False(entry.Applicable));
    }
}
