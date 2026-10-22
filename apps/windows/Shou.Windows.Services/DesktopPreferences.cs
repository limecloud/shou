using System.Globalization;
using System.Text.Json;

namespace Shou.Windows.Services;

/// <summary>Presentation preferences never grant filesystem or engine permissions.</summary>
public sealed record DesktopPreferences(string Language = "system", string Appearance = "system", bool ReduceMotion = false)
{
    public void Validate()
    {
        if (Language is not ("system" or "zh-CN" or "en") || Appearance is not ("system" or "light" or "dark"))
            throw new FormatException("Unsupported desktop preferences.");
    }

    public string ResolveLanguage(CultureInfo systemLanguage)
    {
        Validate();
        return Language == "system" ? systemLanguage.TwoLetterISOLanguageName == "zh" ? "zh-CN" : "en" : Language;
    }

    public bool UsesReducedMotion(bool systemAnimationsEnabled, bool highContrast) => ReduceMotion || !systemAnimationsEnabled || highContrast;
}

/// <summary>Separate from the engine's private records; writes are atomic and bounded.</summary>
public sealed class DesktopPreferenceStore(string path)
{
    public static string DefaultPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shou.Desktop", "preferences.json");
    public string FilePath { get; } = Path.GetFullPath(path);

    public DesktopPreferences Read()
    {
        if (!File.Exists(FilePath)) return new();
        if ((File.GetAttributes(FilePath) & FileAttributes.ReparsePoint) != 0) throw new IOException("Desktop preferences cannot be a link.");
        using var stream = new FileStream(FilePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length > 8192) throw new FormatException("Desktop preferences exceed their limit.");
        using var json = JsonDocument.Parse(stream);
        var root = json.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new FormatException("Invalid desktop preferences.");
        var keys = root.EnumerateObject().Select(property => property.Name).ToArray();
        if (keys.Length != 4 || keys.Distinct().Count() != 4 || !keys.Order(StringComparer.Ordinal).SequenceEqual(new[] { "appearance", "language", "reduce_motion", "version" }) ||
            root.GetProperty("version").ValueKind != JsonValueKind.Number ||
            !root.GetProperty("version").TryGetInt32(out var version) || version != 1 ||
            root.GetProperty("language").ValueKind != JsonValueKind.String || root.GetProperty("appearance").ValueKind != JsonValueKind.String ||
            root.GetProperty("reduce_motion").ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw new FormatException("Unsupported desktop preferences schema.");
        var result = new DesktopPreferences(root.GetProperty("language").GetString()!, root.GetProperty("appearance").GetString()!, root.GetProperty("reduce_motion").GetBoolean());
        result.Validate();
        return result;
    }

    public void Save(DesktopPreferences preferences)
    {
        preferences.Validate();
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new { version = 1, language = preferences.Language, appearance = preferences.Appearance, reduce_motion = preferences.ReduceMotion });
        var folder = Path.GetDirectoryName(FilePath)!;
        Directory.CreateDirectory(folder);
        if ((File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0) throw new IOException("Desktop preferences directory cannot be a link.");
        var temporary = Path.Combine(folder, ".preferences-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                stream.Write(bytes); stream.Flush(true);
            }
            File.Move(temporary, FilePath, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
