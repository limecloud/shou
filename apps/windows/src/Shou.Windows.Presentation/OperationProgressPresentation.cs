using System.Text;

namespace Shou.Windows.Presentation;

public static class OperationProgressPresentation
{
    public static string CompactPath(string path)
    {
        var runes = path.EnumerateRunes().Select(rune => Rune.IsControl(rune) ? new Rune(' ') : rune).ToArray();
        if (runes.Length <= 100) return string.Concat(runes.Select(rune => rune.ToString()));
        return string.Concat(runes.Take(36).Select(rune => rune.ToString())) + "…" + string.Concat(runes.TakeLast(60).Select(rune => rune.ToString()));
    }
}
