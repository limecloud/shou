using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using IconPath = Microsoft.UI.Xaml.Shapes.Path;

namespace Shou.Windows.App;

/// <summary>Product-owned vector symbols; no platform font or SF Symbols asset is embedded.</summary>
internal static class ProductIcon
{
    public static FrameworkElement Create(string name, double size = 14)
    {
        if (name == "drive" && size >= 40) return FilledDrive(size);
        if (name == "cleanup") return CleanupSymbol(size);
        if (name is "document" or "document-text") return FilledDocument(size, name == "document-text");
        if (name == "intake") return FilledIntake(size);
        var data = name switch
        {
            "search" => "M10.5,10.5 L15,15 M12,6.5 A5.5,5.5 0 1 1 1,6.5 A5.5,5.5 0 1 1 12,6.5",
            "large" => "M3,1 L10,1 L13,4 L13,10 M10,1 L10,4 L13,4 M3,1 L3,14 L8,14 M9.5,10 A2.5,2.5 0 1 1 14.5,10 A2.5,2.5 0 1 1 9.5,10 M13.7,11.8 L16,14.5",
            "storage" => "M1,1 L6,1 L6,6 L1,6 Z M10,1 L15,1 L15,6 L10,6 Z M1,10 L6,10 L6,15 L1,15 Z M10,10 L15,10 L15,15 L10,15 Z",
            "configuration" => "M15,8 A7,7 0 1 1 1,8 A7,7 0 1 1 15,8 M4,5 L12,5 M4,8 L12,8 M4,11 L9,11 M6,4 L6,6 M10,7 L10,9 M6,10 L6,12",
            "startup" => "M8,1 L8,8 M4.5,3 A6,6 0 1 0 11.5,3 M5.5,5 A3.5,3.5 0 1 0 10.5,5",
            "applications" => "M8,1 L15,4.5 L15,12 L8,15.5 L1,12 L1,4.5 Z M1,4.5 L8,8 L15,4.5 M8,8 L8,15.5 M4.5,2.8 L11.5,6.3",
            "privacy" => "M5,13 L2.5,9.5 Q1.5,7.5 3.5,7.5 L5,9 L5,3 Q5,1 6.5,2 L6.5,8 L7,1.5 Q8,0 8.5,2 L8.5,8 L9.5,3 Q10.5,1.5 11,3 L10.5,9 L12,6 Q13,5 13.5,6.5 L12,12 Q11,15 8,15 Z",
            "history" => "M2,5 A6.5,6.5 0 1 1 1.5,10 M1,1 L1,6 L6,6 M8,4 L8,8 L11,10",
            "cookie" => "M12,13.5 A7,7 0 1 1 15,7 M6,5 A2,2 0 1 0 10,5 A2,2 0 1 0 6,5 M4.5,12 Q4.5,8.5 8,8.5 Q10,8.5 11,10 M14,10 L14,12.5 M14,14.5 L14,15",
            "settings" => "M6,1 L10,1 L10.5,3 L12.5,4 L14.5,3.5 L16,7 L14.5,8.5 L14,10.5 L14.5,12.5 L11,14.5 L9.5,13 L7.5,13 L6,14.5 L2.5,12.5 L3,10.5 L2.5,8.5 L1,7 L2.5,3.5 L4.5,4 L6,3 Z M5.5,8 A2.5,2.5 0 1 0 10.5,8 A2.5,2.5 0 1 0 5.5,8",
            "language" => "M15,8 A7,7 0 1 1 1,8 A7,7 0 1 1 15,8 M1,8 L15,8 M2.5,4 L13.5,4 M2.5,12 L13.5,12 M8,1 C3,4 3,12 8,15 M8,1 C13,4 13,12 8,15",
            "appearance" => "M15,8 A7,7 0 1 1 1,8 A7,7 0 1 1 15,8 M8,1 L8,15 M7,2 L7,14 M6,2 L6,14 M5,3 L5,13 M4,3 L4,13 M3,5 L3,11",
            "motion" => "M15,8 A7,7 0 1 1 1,8 A7,7 0 1 1 15,8 M6,5 L6,11 M10,5 L10,11",
            "drive" => "M2,10 L4,3 Q4,2 6,2 L12,2 Q14,2 14,3 L16,10 M2,10 L16,10 L16,15 L2,15 Z M5,12 L5,13 M8,12 L8,13 M11,12 L11,13 M14,12 L14,13",
            "terminal" or "projects" => "M2,2 L14,2 Q15,2 15,3 L15,13 Q15,14 14,14 L2,14 Q1,14 1,13 L1,3 Q1,2 2,2 Z M4,5 L7,8 L4,11 M9,11 L12,11",
            "archive" => "M1,2 L15,2 L15,5 L1,5 Z M3,5 L3,14 L13,14 L13,5 M6,8 L10,8",
            "tray" => "M2,5 L5,2 L11,2 L14,5 M2,5 L14,5 L15,13 L1,13 Z M2,7 L5,7 L6,9 L10,9 L11,7 L14,7 M5,5 L11,5",
            "hammer" => "M2,3 L5,1 L9,4 L8,6 L15,13 L13,15 L6,8 L4,9 L3,7 L5,5 Z",
            "complete" => "M15,8 A7,7 0 1 1 1,8 A7,7 0 1 1 15,8 M4,8 L7,11 L12,5.5",
            "paused" => "M15,8 A7,7 0 1 1 1,8 A7,7 0 1 1 15,8 M6,5 L6,11 M10,5 L10,11",
            "warning" => "M7,1.8 Q8,0 9,1.8 L15,13 Q16,15 14,15 L2,15 Q0,15 1,13 Z M8,5 L8,9.5 M8,12 L8,12.3",
            _ => "M1,2 L15,2 L15,14 L1,14 Z M5,2 L5,14"
        };
        var stroke = size >= 40 ? 0.8 : 1.15;
        var path = (IconPath)XamlReader.Load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='" + data + "' StrokeThickness='" + stroke.ToString(System.Globalization.CultureInfo.InvariantCulture) + "' StrokeLineJoin='Round' Width='17' Height='17' />");
        path.Stroke = (Brush)Application.Current.Resources["ShouAccentBrush"];
        return new Viewbox { Child = path, Width = size, Height = size, Stretch = Stretch.Uniform };
    }

    public static void Select(FrameworkElement element, Brush brush)
    {
        if (element is Viewbox { Child: IconPath path }) path.Stroke = brush;
        else if (element is Viewbox { Child: Grid layers })
            foreach (var layer in layers.Children.OfType<IconPath>())
            {
                if (layer.Stroke is not null) layer.Stroke = brush;
                if (layer.Fill is not null) layer.Fill = brush;
            }
    }

    private static FrameworkElement CleanupSymbol(double size)
    {
        var stroke = (size >= 40 ? 0.8 : 1.15).ToString(System.Globalization.CultureInfo.InvariantCulture);
        var layers = (Grid)XamlReader.Load("<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Width='15' Height='15'>" +
            "<Path Data='M10.5,10.5 L14.5,14.5 M12,6.5 A5.5,5.5 0 1 1 1,6.5 A5.5,5.5 0 1 1 12,6.5' Stroke='Black' StrokeThickness='" + stroke + "' StrokeStartLineCap='Round' StrokeEndLineCap='Round' />" +
            "<Path Data='M6.5,3 Q7,5.5 7.5,5.5 L10,6.5 Q7.5,7 7.5,7.5 L6.5,10 Q6,7.5 5.5,7.5 L3,6.5 Q5.5,6 5.5,5.5 Z' Fill='Black' /></Grid>");
        var result = new Viewbox { Child = layers, Width = size, Height = size, Stretch = Stretch.Uniform };
        Select(result, (Brush)Application.Current.Resources["ShouAccentBrush"]);
        return result;
    }

    private static FrameworkElement FilledDrive(double size)
    {
        // The front slots are cutouts so the same silhouette works on either theme.
        const string data = "F0 M3,7.5 L5,2.5 Q5.6,1 7,1 L17,1 Q18.4,1 19,2.5 L21,7.5 Q19.8,7 18.5,7 L5.5,7 Q4.2,7 3,7.5 Z " +
            "M5,8 L19,8 A4,4 0 0 1 19,16 L5,16 A4,4 0 0 1 5,8 Z " +
            "M9,10.2 L9,13.8 A0.5,0.5 0 0 1 8,13.8 L8,10.2 A0.5,0.5 0 0 1 9,10.2 Z " +
            "M11.5,10.2 L11.5,13.8 A0.5,0.5 0 0 1 10.5,13.8 L10.5,10.2 A0.5,0.5 0 0 1 11.5,10.2 Z " +
            "M14,10.2 L14,13.8 A0.5,0.5 0 0 1 13,13.8 L13,10.2 A0.5,0.5 0 0 1 14,10.2 Z " +
            "M16.5,10.2 L16.5,13.8 A0.5,0.5 0 0 1 15.5,13.8 L15.5,10.2 A0.5,0.5 0 0 1 16.5,10.2 Z " +
            "M19,10.2 L19,13.8 A0.5,0.5 0 0 1 18,13.8 L18,10.2 A0.5,0.5 0 0 1 19,10.2 Z";
        var path = (IconPath)XamlReader.Load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='" + data + "' Width='24' Height='20' />");
        path.Fill = (Brush)Application.Current.Resources["ShouAccentBrush"];
        return new Viewbox { Width = size * 24 / 20, Height = size, Child = new Grid { Width = 24, Height = 20, Children = { path } } };
    }

    private static FrameworkElement FilledDocument(double size, bool text)
    {
        const string outline = "F0 M3,1 L10,1 L14,5 L14,15 L3,15 Z M10,2 L10,5 L13,5 Z ";
        return FilledSymbol(outline + (text ? "M5,8 L12,8 L12,9 L5,9 Z M5,11 L10,11 L10,12 L5,12 Z" : ""), size);
    }

    private static FrameworkElement FilledIntake(double size) => FilledSymbol(
        "F0 M2,6 L5,2 L11,2 L14,6 L15,13 L1,13 Z M3,6 L5,3 L11,3 L13,6 L10.5,6 L9.5,8 L6.5,8 L5.5,6 Z", size);

    private static FrameworkElement FilledSymbol(string data, double size)
    {
        var path = (IconPath)XamlReader.Load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='" + data + "' Width='17' Height='17' />");
        path.Fill = (Brush)Application.Current.Resources["ShouAccentBrush"];
        return new Viewbox { Child = path, Width = size, Height = size, Stretch = Stretch.Uniform };
    }
}
