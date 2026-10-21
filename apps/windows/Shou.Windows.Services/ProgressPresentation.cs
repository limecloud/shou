using System.Globalization;

namespace Shou.Windows.Services;

public static class ProgressPresentation
{
    public static string ShortPath(string path, int maximumLength = 64)
    {
        var clean = path.Replace('\\', '/').Replace("\r\n", " ")
            .Replace('\r', ' ').Replace('\n', ' ').Replace('\t', ' ')
            .Replace('\v', ' ').Replace('\f', ' ').Replace('\u0085', ' ')
            .Replace('\u2028', ' ').Replace('\u2029', ' ');
        var characters = StringInfo.ParseCombiningCharacters(clean);
        if (characters.Length <= maximumLength) return clean;
        if (maximumLength <= 0) return "";
        if (maximumLength == 1) return "…";
        var retained = maximumLength - 1;
        var prefix = (int)Math.Round(retained * (24.0 / 63), MidpointRounding.AwayFromZero);
        var suffix = retained - prefix;
        return clean[..characters[prefix]] + "…" + clean[(suffix == 0 ? clean.Length : characters[^suffix])..];
    }

    public static string FitPath(string path, Func<string, bool> fits)
    {
        var candidate = ShortPath(path);
        if (fits(candidate)) return candidate;
        var lower = 0;
        var upper = Math.Min(64, StringInfo.ParseCombiningCharacters(candidate).Length);
        while (lower < upper)
        {
            var middle = (lower + upper + 1) / 2;
            if (fits(ShortPath(path, middle))) lower = middle;
            else upper = middle - 1;
        }
        return ShortPath(path, lower);
    }
}
