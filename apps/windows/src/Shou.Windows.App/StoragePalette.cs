using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Shou.Windows.Presentation;
using Shou.Windows.Core;
using System.Text;

namespace Shou.Windows.App;

internal static class StoragePalette
{
    public static Brush Simple(WindowsPath path, WindowsPath root)
    {
        var relative = path.Value[root.Value.Length..].TrimStart('\\').Replace('\\', '/');
        ulong hash = 5381;
        foreach (var value in Encoding.UTF8.GetBytes(relative)) hash = unchecked(hash * 33 + value);
        string[] keys = ["ShouSimpleMapBlue", "ShouSimpleMapGreen", "ShouSimpleMapPurple", "ShouSimpleMapOrange", "ShouSimpleMapTeal", "ShouSimpleMapRose"];
        return new SolidColorBrush((global::Windows.UI.Color)Application.Current.Resources[keys[hash % (ulong)keys.Length]]);
    }
    public static Brush Extension(string suffix) => BrushFor(new(WindowsPath.Parse("C:/palette"), "file" + suffix, false, 0, 0, false));
    public static Brush BrushFor(StorageRow? row)
    {
        var resources = Application.Current.Resources;
        if (new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast)
            return (Brush)resources["ShouMapBrush"];
        var key = row?.IsDirectory == true || row is null ? "ShouMapDirectory" : StorageAnalysis.Extension(row.Name) switch
        {
            "" => "ShouMapUnknown",
            ".js" or ".mjs" or ".cjs" => "ShouMapScript",
            ".dll" or ".so" or ".dylib" => "ShouMapLibrary",
            ".sqlite" or ".sqlite3" => "ShouMapSqlite",
            ".bin" => "ShouMapBinary", ".db" => "ShouMapDatabase", ".json" => "ShouMapJson",
            ".zip" or ".gz" or ".xz" or ".zst" or ".7z" or ".rar" => "ShouMapArchive",
            ".png" or ".jpg" or ".jpeg" or ".webp" or ".heic" => "ShouMapImage",
            ".dmg" or ".iso" => "ShouMapDisk", ".pack" or ".pak" => "ShouMapPackage",
            ".map" => "ShouMapSourceMap", ".ts" or ".tsx" => "ShouMapTypeScript",
            ".go" => "ShouMapGo", ".py" or ".pyc" => "ShouMapPython", ".node" => "ShouMapNode",
            ".html" or ".css" => "ShouMapWeb", ".log" or ".dat" or ".asar" => "ShouMapData",
            _ => "ShouMapSurface"
        };
        return new SolidColorBrush((global::Windows.UI.Color)resources[key]);
    }
}
