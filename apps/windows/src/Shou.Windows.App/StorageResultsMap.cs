using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class StoragePageView
{
    private void DrawMap()
    {
        SpaceMap.Children.Clear();
        if (analysis is null || rendered is null || largeFiles) return;
        SpaceMap.Background = detailed ? new SolidColorBrush((global::Windows.UI.Color)Application.Current.Resources["ShouDetailedMapBackground"]) : ThemeBrush("ShouCanvasBrush");
        var tiles = detailed ? analysis.NestedMap(rows, SpaceMap.ActualWidth, SpaceMap.ActualHeight) :
            StorageAnalysis.Layout(StorageAnalysis.MapItems(rows, 161), SpaceMap.ActualWidth, SpaceMap.ActualHeight)
                .Select(tile => new StorageNestedTile(tile, rows.FirstOrDefault(row => row.Path == tile.Item.Path), 0));
        var any = false;
        foreach (var nested in tiles)
        {
            var tile = nested.Tile; var row = nested.Row;
            var gap = detailed ? 1 : Metric("ShouStorageTileGap");
            if (tile.Width <= gap || tile.Height <= gap) continue;
            any = true;
            var label = tile.Item.Path is null ? text.Get("Other Entries") : tile.Item.Name;
            var selected = row is not null && selection?.Contains(row.Path) == true;
            var focused = row is not null && focus?.Path == row.Path;
            var body = new Grid { Width = tile.Width - gap, Height = tile.Height - gap,
                CornerRadius = new(detailed ? 0 : Metric("ShouStorageTileRadius")),
                Background = detailed ? StoragePalette.BrushFor(row) : row is null ? ThemeBrush("ShouMapBrush") : StoragePalette.Simple(row.Path, rendered.Root),
                BorderBrush = ThemeBrush("ShouMapTextBrush"), BorderThickness = new(selected || focused ? 2 : 0),
                Opacity = detailed && extensionFilter is not null && row?.IsDirectory != true && StorageAnalysis.Extension(row?.Name ?? "") != extensionFilter ? 0.25 : 1 };
            if (tile.Width > 65 && tile.Height > (detailed ? 16 : 42))
            {
                var caption = new StackPanel { Spacing = detailed ? 0 : 5, VerticalAlignment = detailed ? VerticalAlignment.Top : VerticalAlignment.Bottom,
                    Margin = new(detailed ? 3 : Metric("ShouStorageTilePadding")) };
                caption.Children.Add(new TextBlock { Text = label, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = detailed ? 1 : 2,
                    FontSize = detailed ? Metric("ShouStorageTableFontSize") : tile.Width > 200 ? 15 : 12, Foreground = ThemeBrush("ShouMapTextBrush") });
                if (!detailed || row?.IsDirectory != true) caption.Children.Add(new TextBlock { Text = (row?.IsPartial == true ? "≥ " : "") + StorageRow.FormatBytes(tile.Item.Bytes),
                    FontSize = Metric("ShouStorageTableFontSize"), Foreground = ThemeBrush("ShouMapTextBrush"), Opacity = 0.85 });
                body.Children.Add(caption);
            }
            if (row is not null)
            {
                AutomationProperties.SetName(body, label + ", " + row.DisplaySize);
                ToolTipService.SetToolTip(body, row.Path.Value + ", " + row.DisplaySize);
                body.Tapped += (_, args) => { Inspect(row); args.Handled = true; };
                body.DoubleTapped += (_, args) => { if (row.IsDirectory) OpenDirectory(row.Path); args.Handled = true; };
                if (!detailed && tile.Width > 65 && tile.Height > 42 && selection?.CanSelect(row) == true)
                {
                    var toggle = new Button { Content = selected ? "●" : "○", Style = ProductStyle("ShouToolbarButton"), FontSize = 22,
                        HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new(4),
                        Foreground = ThemeBrush("ShouMapTextBrush"), Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(0, 0, 0, 0)) };
                    AutomationProperties.SetName(toggle, text.Get("Select Item") + " " + row.Name);
                    toggle.Click += (_, _) => { selection.Set(row, !selection.Contains(row.Path)); RenderStorageResults(); UpdateSelection(); };
                    body.Children.Add(toggle);
                }
            }
            Canvas.SetLeft(body, tile.X); Canvas.SetTop(body, tile.Y); SpaceMap.Children.Add(body);
        }
        if (!any)
        {
            var empty = new TextBlock { Text = text.Get("No allocated data in this folder"), Style = ProductStyle("ShouCaption"), Margin = new(Metric("ShouStorageChartPadding")) };
            SpaceMap.Children.Add(empty);
        }
    }
}
