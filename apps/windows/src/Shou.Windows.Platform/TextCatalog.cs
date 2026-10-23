using System.Globalization;
using System.Reflection;
using System.Text.Json;

namespace Shou.Windows.Platform;

public sealed class TextCatalog
{
    private readonly Dictionary<string, TextEntry> entries;
    public string Locale { get; }

    public TextCatalog(string? locale = null)
    {
        Locale = (locale ?? CultureInfo.CurrentUICulture.Name).StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-CN" : "en-US";
        using var resource = typeof(TextCatalog).Assembly.GetManifestResourceStream($"Shou.Windows.Resources.Text.{Locale}.json")
            ?? throw new InvalidOperationException("The language resources are missing.");
        entries = JsonSerializer.Deserialize<Dictionary<string, TextEntry>>(resource)
            ?? throw new InvalidOperationException("The language resources are invalid.");
    }

    public string Get(string key) => entries.TryGetValue(key, out var entry) ? entry.Text : key;
    public string Format(string key, params object[] arguments) => string.Format(CultureInfo.GetCultureInfo(Locale),
        entries.TryGetValue(key, out var entry) ? entry.Format : key, arguments);

    private sealed record TextEntry(
        [property: System.Text.Json.Serialization.JsonPropertyName("text")] string Text,
        [property: System.Text.Json.Serialization.JsonPropertyName("format")] string Format);
}
