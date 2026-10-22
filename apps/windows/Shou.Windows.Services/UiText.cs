using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Shou.Windows.Services;

/// <summary>Only application-owned messages enter this catalog, never user paths or content.</summary>
public static class UiText
{
    private static readonly IReadOnlyDictionary<string, string> English = Load();
    private static readonly IReadOnlyDictionary<string, string> Sources = English.Keys.ToDictionary(Key, value => value);
    private static readonly IReadOnlyDictionary<string, string> CoreChinese = LoadCoreCatalog("Shou.Core.Chinese.strings");
    private static readonly IReadOnlyDictionary<string, string> CoreEnglish = LoadCoreCatalog("Shou.Core.English.strings");
    public static string RequestedLanguage { get; private set; } = "zh-CN";
    public static string Language { get; private set; } = "zh-CN";

    public static void SetLanguage(string language, CultureInfo systemLanguage)
    {
        var resolved = new DesktopPreferences(Language: language).ResolveLanguage(systemLanguage);
        RequestedLanguage = language; Language = resolved;
        CultureInfo.DefaultThreadCurrentUICulture = CultureInfo.GetCultureInfo(Language);
        CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(Language);
    }

    public static string T(string source) => Language == "en" ? English.GetValueOrDefault(source, CoreEnglish.GetValueOrDefault(source, source)) : CoreChinese.GetValueOrDefault(source, source);
    public static string F(string source, params object?[] arguments) => string.Format(CultureInfo.CurrentCulture, T(source), arguments);
    public static string FromKey(string key) => Sources.TryGetValue(key, out var source) ? T(source) : throw new InvalidOperationException("Unknown UI catalog key: " + key);
    public static string Key(string source) => "t" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(source)))[..16];
    public static IReadOnlyDictionary<string, string> Catalog => English;

    private static IReadOnlyDictionary<string, string> Load()
    {
        using var stream = typeof(UiText).Assembly.GetManifestResourceStream("Shou.Windows.UiStrings.json") ?? throw new InvalidOperationException("Missing Windows interface catalog.");
        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream) ?? throw new InvalidOperationException("Invalid Windows interface catalog.");
    }

    private static IReadOnlyDictionary<string, string> LoadCoreCatalog(string resource)
    {
        using var stream = typeof(UiText).Assembly.GetManifestResourceStream(resource) ?? throw new InvalidOperationException("Missing shared interface catalog.");
        using var reader = new StreamReader(stream);
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        while (reader.ReadLine() is { } line)
        {
            if (string.IsNullOrWhiteSpace(line) || line.StartsWith("//", StringComparison.Ordinal)) continue;
            var match = Regex.Match(line, """^("(?:[^"\\]|\\.)*") = ("(?:[^"\\]|\\.)*");$""");
            if (!match.Success) throw new InvalidOperationException("Invalid shared interface catalog line.");
            result.Add(JsonSerializer.Deserialize<string>(match.Groups[1].Value)!, JsonSerializer.Deserialize<string>(match.Groups[2].Value)!);
        }
        return result;
    }
}
