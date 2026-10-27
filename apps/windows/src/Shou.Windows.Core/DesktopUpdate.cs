using System.Text.Json;
using System.Text.RegularExpressions;

namespace Shou.Windows.Core;

// Desktop self-update metadata is separate from discovery for other installed apps.
public sealed record DesktopUpdate(string Version, string Notes, Uri DownloadUrl, bool IsNewer)
{
    public const int MaximumMetadataBytes = 1_048_576;

    public static DesktopUpdate Parse(byte[] bytes, string currentVersion, string architecture)
    {
        if (bytes.Length > MaximumMetadataBytes || architecture is not ("x64" or "arm64")) throw Invalid();
        try
        {
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 16 });
            var release = document.RootElement;
            var tag = release.GetProperty("tag_name").GetString() ?? "";
            if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean() || !tag.StartsWith('v')) throw Invalid();
            var version = ParseVersion(tag[1..]);
            var current = ParseVersion(currentVersion);
            var prefix = "https://github.com/limecloud/shou/releases/";
            if (release.GetProperty("html_url").GetString() != prefix + "tag/" + tag) throw Invalid();
            var filename = $"Shou-{version}-windows-{architecture}.zip";
            var download = prefix + $"download/{tag}/{filename}";
            var matches = release.GetProperty("assets").EnumerateArray().Where(asset =>
                asset.GetProperty("name").GetString() == filename &&
                asset.GetProperty("browser_download_url").GetString() == download &&
                asset.GetProperty("size").GetInt64() > 0).ToArray();
            if (matches.Length != 1) throw Invalid();
            var notes = release.TryGetProperty("body", out var body) && body.ValueKind == JsonValueKind.String ? body.GetString() ?? "" : "";
            if (notes.Length > 65_536) notes = notes[..65_536];
            return new(version.ToString(), notes, new Uri(download), version > current);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException)
        { throw Invalid(); }
    }

    private static System.Version ParseVersion(string value)
    {
        if (value.Length > 32 || !Regex.IsMatch(value, @"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z", RegexOptions.CultureInvariant)) throw Invalid();
        return System.Version.Parse(value);
    }
    private static ShouException Invalid() => new("desktop_update_unavailable", "The desktop release metadata is unavailable or unsupported.");
}
