using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public sealed record RuleCatalogEntry(string Id, string Version, string Name, string Description, string Patterns,
    bool Builtin, bool Applicable, bool Enabled, string Limitation = "", string Location = "");

public static class RuleCatalog
{
    public static ImmutableArray<RuleCatalogEntry> Read(BuiltinRuleCatalog catalog, Configuration configuration, Workspace? workspace,
        string source = "all", string query = "")
    {
        var applicable = workspace is null ? [] : catalog.RulesFor(workspace);
        var builtins = catalog.Templates.Select(template =>
        {
            var rule = applicable.FirstOrDefault(value => value.Id == template.Id);
            var binding = configuration.Bindings.FirstOrDefault(value => value.WorkspaceId == workspace?.Id && value.RuleId == template.Id);
            var location = template.Location == "projects" ? "Developer Projects" :
                catalog.Locations.FirstOrDefault(item => item.Id == template.Location)?.Title ?? template.Location;
            return new RuleCatalogEntry(template.Id, template.Version, template.Name, template.RebuildNote, string.Join(", ", template.Patterns),
                true, rule is not null, rule is not null && (binding?.Enabled ?? true), template.Limitation, location);
        });
        var personal = configuration.Rules.Select(record =>
        {
            var choice = RuleVersionChoice.From(record);
            var binding = configuration.Bindings.FirstOrDefault(value => value.WorkspaceId == workspace?.Id && value.RuleId == choice.Id && value.Version == choice.Version);
            var patterns = string.Join(", ", record.Rule.GetProperty("match").GetProperty("relative_patterns").EnumerateArray().Select(value => value.GetString()));
            return new RuleCatalogEntry(choice.Id, choice.Version, choice.Name, choice.Description, patterns,
                false, choice.AppliesToWindows && workspace?.RootRef == choice.RootReference, binding?.Enabled == true);
        });
        return builtins.Concat(personal).Where(value => (source != "builtin" || value.Builtin) && (source != "personal" || !value.Builtin) &&
            (value.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || value.Patterns.Contains(query, StringComparison.OrdinalIgnoreCase) || value.Id.Contains(query, StringComparison.OrdinalIgnoreCase)))
            .OrderBy(value => value.Name, StringComparer.Ordinal).ThenBy(value => value.Id, StringComparer.Ordinal).ThenBy(value => value.Version, StringComparer.Ordinal).ToImmutableArray();
    }
}
