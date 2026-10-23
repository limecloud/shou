using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public static class RuleResources
{
    public static RuleSchemaValidator CreateValidator()
    {
        using var stream = typeof(RuleResources).Assembly.GetManifestResourceStream("Shou.Windows.Resources.rule.schema.json")
            ?? throw new ShouException("resource_unavailable", "The bundled rule schema is missing.");
        using var bytes = new MemoryStream();
        stream.CopyTo(bytes);
        return new RuleSchemaValidator(bytes.ToArray());
    }

    public static BuiltinRuleCatalog CreateCatalog(RuleSchemaValidator validator, WindowsUserDirectories directories) =>
        new(validator, directories, Read("builtin-rules.json"), Read("known-locations.json"), Read("project-locations.json"));

    private static byte[] Read(string name)
    {
        using var stream = typeof(RuleResources).Assembly.GetManifestResourceStream("Shou.Windows.Resources." + name)
            ?? throw new ShouException("resource_unavailable", "A bundled catalog resource is missing.");
        using var bytes = new MemoryStream();
        stream.CopyTo(bytes);
        return bytes.ToArray();
    }
}
