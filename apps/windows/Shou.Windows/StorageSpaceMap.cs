using System.Globalization;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace Shou.Windows;

/// <summary>One drawing surface; geometry comes from the shared core layout.</summary>
public sealed class StorageSpaceMap : FrameworkElement
{
    public static readonly DependencyProperty DataProperty = DependencyProperty.Register(nameof(Data), typeof(JsonNode), typeof(StorageSpaceMap), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty FocusPathProperty = DependencyProperty.Register(nameof(FocusPath), typeof(string), typeof(StorageSpaceMap), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty ExtensionProperty = DependencyProperty.Register(nameof(Extension), typeof(string), typeof(StorageSpaceMap), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public JsonNode? Data { get => (JsonNode?)GetValue(DataProperty); set => SetValue(DataProperty, value); }
    public string? FocusPath { get => (string?)GetValue(FocusPathProperty); set => SetValue(FocusPathProperty, value); }
    public string? Extension { get => (string?)GetValue(ExtensionProperty); set => SetValue(ExtensionProperty, value); }
    public event Action<string, bool>? Inspect;
    private static string Text(JsonNode? node, string key) => node?[key]?.GetValue<string>() ?? "";
    private Rect Bounds(JsonNode tile) => new((tile["x"]?.GetValue<double>() ?? 0) / 1000 * ActualWidth, (tile["y"]?.GetValue<double>() ?? 0) / 600 * ActualHeight, Math.Max(0, (tile["width"]?.GetValue<double>() ?? 0) / 1000 * ActualWidth - 0.7), Math.Max(0, (tile["height"]?.GetValue<double>() ?? 0) / 600 * ActualHeight - 0.7));
    private static string Suffix(string path) { var name=path.Split('/').Last(); var dot=name.LastIndexOf('.'); return dot <= 0 || dot == name.Length-1 ? "" : name[(dot+1)..].ToLowerInvariant(); }
    protected override void OnRender(DrawingContext drawing)
    {
        drawing.DrawRectangle(new SolidColorBrush(Color.FromRgb(26,26,26)), null, new Rect(RenderSize));
        if (Data?["tiles"] is not JsonArray tiles) return;
        var nodes=(Data["presentation"]?["items"] as JsonArray)?.OfType<JsonObject>().Select(item=>item["node"]!).ToDictionary(node=>Text(node,"path")) ?? new();
        foreach (var tile in tiles.OfType<JsonObject>()) {
            var path=Text(tile,"path"); var rect=Bounds(tile); var remainder=tile["remainder"]?.GetValue<bool>() == true;
            if(rect.Width<0.5 || rect.Height<0.5) continue;
            nodes.TryGetValue(path,out var node); var directory=Text(node,"kind")=="directory";
            var aggregate=tile["aggregate"]; var suffix=aggregate is not null ? Text(aggregate,"suffix") : Suffix(path); var matching=(Text(node,"kind")=="file" || aggregate is not null) && suffix==Extension;
            var color=(Color)ColorConverter.ConvertFromString(Data["colors"]?[suffix]?.GetValue<string>() ?? "#76877E");
            if(directory || remainder) drawing.DrawRectangle(new SolidColorBrush(Color.FromRgb(53,53,53)),null,rect);
            else {
                Color Shade(double factor) => Color.FromRgb((byte)Math.Min(255,color.R*factor),(byte)Math.Min(255,color.G*factor),(byte)Math.Min(255,color.B*factor));
                var surface=new LinearGradientBrush { StartPoint=new Point(0.5,0),EndPoint=new Point(0.5,1),Opacity=Extension is null || matching ? 1 : 0.25,GradientStops=[new(Shade(0.45),0),new(Shade(1.15),0.48),new(Shade(0.42),1)] };
                drawing.DrawRectangle(surface,null,rect);
                drawing.DrawRectangle(new LinearGradientBrush { StartPoint=new Point(0,0.5),EndPoint=new Point(1,0.5),GradientStops=[new(Color.FromArgb(115,0,0,0),0),new(Colors.Transparent,0.5),new(Color.FromArgb(115,0,0,0),1)] },null,rect);
            }
            if (rect.Width > 64 && rect.Height > 15) {
                var name=remainder ? T("其他项目") : aggregate is not null ? (suffix.Length==0 ? T("无扩展名") : "."+suffix)+" × "+(aggregate["file_count"]?.GetValue<int>() ?? 0).ToString("N0") : path.Split('/').Last();
                var size=MainViewModel.Bytes(aggregate?["allocated_bytes"]?.GetValue<long>() ?? node?["allocated_bytes"]?.GetValue<long>() ?? 0);
                var label=new FormattedText(directory ? name+" ("+size+")" : name, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"),9, Brushes.White, VisualTreeHelper.GetDpi(this).PixelsPerDip) { MaxTextWidth=Math.Max(1,rect.Width-6), MaxTextHeight=12, Trimming=TextTrimming.CharacterEllipsis };
                drawing.DrawText(label,new Point(rect.X+3,rect.Y));
                if(!directory && rect.Height>34) drawing.DrawText(new FormattedText(size,CultureInfo.CurrentUICulture,FlowDirection.LeftToRight,new Typeface("Segoe UI"),9,Brushes.White,VisualTreeHelper.GetDpi(this).PixelsPerDip),new Point(rect.X+3,rect.Y+13));
            }
        }
        foreach(var tile in tiles.OfType<JsonObject>().Where(tile=>tile["remainder"]?.GetValue<bool>()!=true)) {
            var path=Text(tile,"path"); nodes.TryGetValue(path,out var node);
            var aggregate=tile["aggregate"]; var matching=Extension is not null && (Text(node,"kind")=="file" || aggregate is not null) && (aggregate is not null ? Text(aggregate,"suffix") : Suffix(path))==Extension;
            if(path==FocusPath || matching) drawing.DrawRectangle(null,new Pen(path==FocusPath ? Brushes.White : Brushes.OrangeRed,path==FocusPath ? 2 : 1),Bounds(tile));
        }
    }
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        if (Data?["tiles"] is not JsonArray tiles) return;
        var tile=tiles.OfType<JsonObject>().LastOrDefault(t => t["remainder"]?.GetValue<bool>() != true && Bounds(t).Contains(e.GetPosition(this)));
        if (tile is not null) Inspect?.Invoke(Text(tile,"inspect_path") is { Length:>0 } target ? target : Text(tile,"path"),e.ClickCount == 2);
    }
}
