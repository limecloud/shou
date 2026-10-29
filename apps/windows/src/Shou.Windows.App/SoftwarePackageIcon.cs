using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Shapes;

namespace Shou.Windows.App;

/// <summary>Offline presentation assets; an icon never grants installation or update authority.</summary>
internal static class SoftwarePackageIcon
{
    private static readonly Lazy<Dictionary<string, Dictionary<string, string>>> catalog = new(() =>
    {
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, Dictionary<string, string>>>(File.ReadAllText(
                System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "SoftwareIcons", "catalog.json"))) ?? [];
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return []; }
    });
    internal static FrameworkElement Create(string packageId)
    {
        var root = catalog.Value;
        if (root.TryGetValue("winget", out var names) && names.TryGetValue(packageId, out var name) &&
            root.TryGetValue("paths", out var paths) && paths.TryGetValue(name, out var data) && data.Length is > 0 and < 100_000 &&
            data.All(character => char.IsAsciiLetterOrDigit(character) || " .,+-\r\n\t".Contains(character)))
        {
            var shape = (Microsoft.UI.Xaml.Shapes.Path)XamlReader.Load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='" + data + "' />");
            ThemeResources.Apply(shape, Shape.FillProperty, "Fill", "ShouAccentBrush");
            return new Viewbox { Child = shape, Width = 24, Height = 24, Margin = new Thickness(4), VerticalAlignment = VerticalAlignment.Center };
        }
        return ProductIcon.Create("applications", 32);
    }
}
