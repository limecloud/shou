using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class StoragePageView
{
    private readonly TextBox SearchBox = new();
    private readonly TextBlock ExtensionsHeading = new(), ItemCount = new(), MapHeading = new(), MapSize = new();
    private readonly TextBlock EmptyDirectory = new();
    private readonly ListView DirectoryTree = new(), ExtensionList = new();
    private readonly Canvas SpaceMap = new();
    private readonly Grid resultsLayout = new(), upperLayout = new(), directoryLayout = new(), chartLayout = new();
    private readonly StackPanel directoryHeader = new(), tableHeader = new();
    private readonly Grid extensionLayout = new(), directoryTable = new();
    private readonly ScrollViewer directoryScroll = new(), extensionScroll = new();
    private readonly Grid chartTitle = new();
    private readonly ComboBox sortPicker = new();
    private readonly CheckBox selectAll = new();
    private readonly Button clearExtension = new();
    private readonly Border verticalDivider = new(), horizontalDivider = new();
    private readonly HashSet<WindowsPath> expandedPaths = [];
    private readonly Dictionary<WindowsPath, int> expandedLimits = [];
    private readonly Dictionary<WindowsPath, Grid> visibleRows = [];
    private StorageSelection? selection;
    private StorageRow? focus;
    private string sort = "size";
    private string? extensionFilter;
    private bool updatingResults;

    private static double Metric(string key) => (double)Application.Current.Resources[key];
    private static Style ProductStyle(string key) => (Style)Application.Current.Resources[key];
    private Brush ThemeBrush(string key)
    {
        var theme = new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast ? "HighContrast" : ActualTheme.ToString();
        foreach (var dictionary in Application.Current.Resources.MergedDictionaries)
            if (dictionary.ThemeDictionaries.TryGetValue(theme, out var value) && value is ResourceDictionary themed && themed.ContainsKey(key))
                return (Brush)themed[key];
        return (Brush)Application.Current.Resources[key];
    }
    private void InitializeResultsLayout()
    {
        StorageResultsHost.Content = resultsLayout;
        resultsLayout.Children.Add(upperLayout); resultsLayout.Children.Add(chartLayout);
        resultsLayout.Children.Add(verticalDivider); resultsLayout.Children.Add(horizontalDivider);
        upperLayout.Children.Add(directoryLayout); upperLayout.Children.Add(extensionLayout);
        directoryLayout.RowDefinitions.Add(new() { Height = GridLength.Auto });
        directoryLayout.RowDefinitions.Add(new() { Height = GridLength.Auto });
        directoryLayout.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        directoryLayout.Children.Add(directoryHeader); directoryLayout.Children.Add(directoryScroll); Grid.SetRow(directoryScroll, 2);
        directoryTable.RowDefinitions.Add(new() { Height = GridLength.Auto }); directoryTable.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        directoryTable.Children.Add(tableHeader); directoryTable.Children.Add(DirectoryTree); Grid.SetRow(DirectoryTree, 1);
        directoryScroll.Content = directoryTable; directoryScroll.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto; directoryScroll.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        DirectoryTree.SelectionMode = ListViewSelectionMode.Single;
        DirectoryTree.ItemContainerStyle = ProductStyle("ShouTableItem");
        DirectoryTree.Padding = new(0); DirectoryTree.KeyDown += DirectoryKeyDown;
        DirectoryTree.SelectionChanged += (_, _) => { if (!updatingResults && DirectoryTree.SelectedItem is Grid { Tag: StorageRow row }) Inspect(row); };
        AutomationProperties.SetAutomationId(DirectoryTree, "storage.tree");
        AutomationProperties.SetName(DirectoryTree, text.Get("Directory Tree"));
        SearchBox.TextChanged += FilterChanged;
        SearchBox.MinWidth = 80; SearchBox.FontSize = Metric("ShouStorageTableFontSize");
        AutomationProperties.SetAutomationId(SearchBox, "storage.search");
        sortPicker.ItemsSource = new[] { text.Get("Size"), text.Get("Name"), text.Get("Files") };
        sortPicker.SelectedIndex = 0; sortPicker.MinWidth = Metric("ShouStorageExtensionWidth");
        sortPicker.SelectionChanged += (_, _) => { sort = sortPicker.SelectedIndex switch { 1 => "name", 2 => "count", _ => "size" }; offset = 0; RefreshResults(); };
        AutomationProperties.SetName(sortPicker, text.Get("Sort"));
        selectAll.MinWidth = selectAll.MinHeight = 0;
        AutomationProperties.SetAutomationId(selectAll, "storage.select-all");
        AutomationProperties.SetName(selectAll, text.Get("Select All in This Folder"));
        selectAll.Click += (_, _) =>
        {
            if (selection is null) return;
            var eligible = rows.Where(selection.CanSelect).ToArray();
            var value = !eligible.All(row => selection.Contains(row.Path));
            foreach (var row in eligible) selection.Set(row, value);
            RenderStorageResults(); UpdateSelection();
        };
        directoryHeader.Children.Add(SearchBox);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Metric("ShouItemSpacing") };
        controls.Children.Add(selectAll); controls.Children.Add(new TextBlock { Text = text.Get("Name"), VerticalAlignment = VerticalAlignment.Center, FontSize = Metric("ShouStorageTableFontSize") });
        controls.Children.Add(sortPicker); controls.Children.Add(ItemCount); directoryHeader.Children.Add(controls);
        chartLayout.RowDefinitions.Add(new() { Height = GridLength.Auto });
        chartLayout.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        chartLayout.RowDefinitions.Add(new() { Height = GridLength.Auto });
        chartTitle.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); chartTitle.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        chartTitle.Children.Add(MapHeading); chartTitle.Children.Add(MapSize); Grid.SetColumn(MapSize, 1);
        MapHeading.TextTrimming = TextTrimming.CharacterEllipsis;
        chartLayout.Children.Add(chartTitle); chartLayout.Children.Add(SpaceMap); Grid.SetRow(SpaceMap, 1);
        var mapHint = new TextBlock { Text = text.Get("Click to inspect. Double-click a folder to open it."), Style = ProductStyle("ShouCaption"), TextWrapping = TextWrapping.Wrap };
        chartLayout.Children.Add(mapHint); Grid.SetRow(mapHint, 2);
        SpaceMap.SizeChanged += MapSizeChanged;
        AutomationProperties.SetAutomationId(SpaceMap, "storage.map");
        var extensionsTitle = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Metric("ShouItemSpacing") };
        extensionsTitle.Children.Add(ExtensionsHeading); extensionsTitle.Children.Add(clearExtension);
        clearExtension.Content = text.Get("Clear"); clearExtension.Style = ProductStyle("ShouToolbarButton");
        clearExtension.Click += (_, _) => { extensionFilter = null; RenderExtensionRows(); DrawMap(); };
        extensionLayout.RowDefinitions.Add(new() { Height = GridLength.Auto }); extensionLayout.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        extensionLayout.Children.Add(extensionsTitle); extensionLayout.Children.Add(extensionScroll); Grid.SetRow(extensionScroll, 1);
        var extensionTable = new Grid(); extensionTable.RowDefinitions.Add(new() { Height = GridLength.Auto }); extensionTable.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        extensionTable.Children.Add(ExtensionHeader()); extensionTable.Children.Add(ExtensionList); Grid.SetRow(ExtensionList, 1);
        extensionScroll.Content = extensionTable; extensionScroll.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto; extensionScroll.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        ExtensionList.ItemContainerStyle = ProductStyle("ShouTableItem");
        ExtensionList.SelectionMode = ListViewSelectionMode.Single; ExtensionList.Padding = new(0);
        ExtensionList.SelectionChanged += (_, _) =>
        {
            if (updatingResults || ExtensionList.SelectedItem is not Grid { Tag: StorageExtension type }) return;
            extensionFilter = type.Extension; clearExtension.Visibility = Visibility.Visible; DrawMap();
        };
        AutomationProperties.SetAutomationId(ExtensionList, "storage.extensions");
        AutomationProperties.SetAutomationId(upperLayout, "storage.tables");
        SetDividerDrag(verticalDivider, vertical: true); SetDividerDrag(horizontalDivider, vertical: false);
        EmptyDirectory.Style = ProductStyle("ShouCaption"); EmptyDirectory.TextAlignment = TextAlignment.Center;
        ActualThemeChanged += (_, _) => { if (analysis is not null) RenderStorageResults(); };
    }
    private void SetDividerDrag(Border divider, bool vertical)
    {
        divider.ManipulationMode = vertical ? ManipulationModes.TranslateX : ManipulationModes.TranslateY;
        divider.ManipulationDelta += (_, args) =>
        {
            if (vertical && !detailed && resultsLayout.ColumnDefinitions.Count > 0)
                resultsLayout.ColumnDefinitions[0].Width = new(Math.Clamp(resultsLayout.ColumnDefinitions[0].ActualWidth + args.Delta.Translation.X, Metric("ShouStorageListMinWidth"), Math.Max(Metric("ShouStorageListMinWidth"), resultsLayout.ActualWidth - Metric("ShouStorageListMinWidth"))));
            else if (!vertical && detailed && resultsLayout.RowDefinitions.Count > 0)
                resultsLayout.RowDefinitions[0].Height = new(Math.Clamp(resultsLayout.RowDefinitions[0].ActualHeight + args.Delta.Translation.Y, 160, Math.Max(160, resultsLayout.ActualHeight - 160)));
        };
    }
    private ImmutableArray<StorageRow> SortedRows(WindowsPath path, string query = "")
    {
        if (analysis is null) return [];
        var values = analysis.Directory(path).Where(row => query.Length == 0 || row.Name.Contains(query, StringComparison.OrdinalIgnoreCase));
        return (sort switch
        {
            "name" => values.OrderBy(row => row.Name, StringComparer.CurrentCultureIgnoreCase),
            "count" => values.OrderByDescending(row => row.FileCount).ThenBy(row => row.Name, StringComparer.Ordinal),
            _ => values.OrderByDescending(row => row.AllocatedBytes).ThenBy(row => row.Name, StringComparer.Ordinal)
        }).ToImmutableArray();
    }
    private void RenderStorageResults()
    {
        if (analysis is null || directory is null || largeFiles) return;
        updatingResults = true;
        try
        {
            resultsLayout.RowDefinitions.Clear(); resultsLayout.ColumnDefinitions.Clear();
            upperLayout.ColumnDefinitions.Clear();
            Grid.SetColumn(chartLayout, detailed ? 0 : 2); Grid.SetRow(chartLayout, detailed ? 2 : 0);
            Grid.SetColumn(horizontalDivider, 0); Grid.SetRow(horizontalDivider, 1);
            Grid.SetColumn(verticalDivider, 1); Grid.SetRow(verticalDivider, 0);
            upperLayout.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            if (detailed)
            {
                resultsLayout.RowDefinitions.Add(new() { Height = new(0.55, GridUnitType.Star), MinHeight = 160 });
                resultsLayout.RowDefinitions.Add(new() { Height = new(Metric("ShouStorageSplitSize")) });
                resultsLayout.RowDefinitions.Add(new() { Height = new(0.45, GridUnitType.Star), MinHeight = 160 });
                upperLayout.ColumnDefinitions.Add(new() { Width = new(0.75, GridUnitType.Star), MinWidth = 285 });
            }
            else
            {
                resultsLayout.ColumnDefinitions.Add(new() { Width = new(Metric("ShouStorageListWidth")), MinWidth = Metric("ShouStorageListMinWidth") });
                resultsLayout.ColumnDefinitions.Add(new() { Width = new(Metric("ShouStorageSplitSize")) });
                resultsLayout.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star), MinWidth = 280 });
            }
            Grid.SetColumn(extensionLayout, 1);
            extensionLayout.Visibility = horizontalDivider.Visibility = detailed ? Visibility.Visible : Visibility.Collapsed;
            verticalDivider.Visibility = detailed ? Visibility.Collapsed : Visibility.Visible;
            verticalDivider.Background = horizontalDivider.Background = ThemeBrush("ShouDividerBrush");
            directoryLayout.Background = extensionLayout.Background = ThemeBrush("ShouSurfaceBrush");
            chartLayout.Padding = new(detailed ? 0 : Metric("ShouStorageChartPadding"));
            chartLayout.RowSpacing = detailed ? 0 : Metric("ShouStorageChartSpacing");
            chartTitle.Padding = new(detailed ? Metric("ShouItemSpacing") : 0);
            MapHeading.FontSize = MapSize.FontSize = Metric(detailed ? "ShouStorageTableFontSize" : "ShouPageTitleSize");
            directoryHeader.Padding = new(Metric("ShouItemSpacing"));
            directoryHeader.Spacing = detailed ? 0 : Metric("ShouItemSpacing");
            SearchBox.Height = Metric("ShouStorageFilterHeight"); SearchBox.MinHeight = 0;
            tableHeader.Visibility = detailed ? Visibility.Visible : Visibility.Collapsed;
            directoryTable.MinWidth = detailed ? new[] { "ShouStorageNameWidth", "ShouStorageShareWidth", "ShouStorageSizeWidth", "ShouStorageSizeWidth", "ShouStorageFilesWidth", "ShouStorageModifiedWidth" }.Sum(Metric) : 0;
            tableHeader.Children.Clear(); tableHeader.Children.Add(DirectoryHeader());
            visibleRows.Clear(); DirectoryTree.Items.Clear();
            foreach (var row in rows.Skip(offset).Take(PageSize)) AddOutlineRow(row, 0, analysis.Directory(directory).Sum(value => value.AllocatedBytes));
            if (rows.IsEmpty)
            {
                EmptyDirectory.Text = text.Get(SearchBox.Text.Length == 0 ? "This folder is empty." : "No matching items.");
                DirectoryTree.Items.Add(EmptyDirectory);
            }
            selectAll.IsEnabled = rows.Any(row => selection?.CanSelect(row) == true);
            var eligible = rows.Where(row => selection?.CanSelect(row) == true).ToArray();
            selectAll.IsThreeState = true; selectAll.IsChecked = eligible.Length == 0 || eligible.All(row => !selection!.Contains(row.Path)) ? false : eligible.All(row => selection!.Contains(row.Path)) ? true : null;
            RenderExtensionRows(); UpdateMapHeading();
        }
        finally { updatingResults = false; }
        DrawMap();
    }
    private void AddOutlineRow(StorageRow row, int depth, long parentBytes)
    {
        if (DirectoryTree.Items.Count >= 2000) return;
        var view = detailed ? DetailedRow(row, depth, parentBytes) : SimpleRow(row, parentBytes);
        view.Tag = row; visibleRows[row.Path] = view; DirectoryTree.Items.Add(view);
        AutomationProperties.SetName(view, row.Name + " · " + row.DisplaySize);
        AutomationProperties.SetAutomationId(view, "storage.row." + row.Path.Value);
        ToolTipService.SetToolTip(view, row.Path.Value);
        view.DoubleTapped += (_, _) => { if (row.IsDirectory) OpenDirectory(row.Path); };
        if (!detailed || !expandedPaths.Contains(row.Path) || depth >= 64 || analysis is null) return;
        var children = SortedRows(row.Path);
        var limit = expandedLimits.GetValueOrDefault(row.Path, PageSize);
        foreach (var child in children.Take(limit)) AddOutlineRow(child, depth + 1, row.AllocatedBytes);
        if (children.Length > limit)
        {
            var more = new Button { Content = text.Get("Show More"), Style = ProductStyle("ShouToolbarButton"), Margin = new(depth * 12, 0, 0, 0) };
            more.Click += (_, _) => { expandedLimits[row.Path] = limit + PageSize; RenderStorageResults(); };
            DirectoryTree.Items.Add(more);
        }
    }
    private CheckBox RowCheck(StorageRow row)
    {
        var check = new CheckBox { MinWidth = 0, MinHeight = 0, IsThreeState = true, VerticalAlignment = VerticalAlignment.Center,
            IsEnabled = selection?.CanSelect(row) == true, IsChecked = selection?.Contains(row.Path) == true ? true : selection?.HasDescendant(row.Path) == true ? null : false };
        AutomationProperties.SetName(check, text.Get("Select Item") + " " + row.Name);
        check.Click += (_, _) => { selection?.Set(row, selection.Contains(row.Path) != true); RenderStorageResults(); UpdateSelection(); };
        return check;
    }
    private Grid SimpleRow(StorageRow row, long parentBytes)
    {
        var view = new Grid { ColumnSpacing = Metric("ShouItemSpacing"), Padding = new(14, 10, 14, 10), MinHeight = Metric("ShouStorageSimpleRowHeight") };
        Columns(view, 18, Metric("ShouStorageRowIconSize"), -1, 20);
        AddCell(view, RowCheck(row), 0);
        AddCell(view, FileIcon(row, Metric("ShouStorageRowIconSize")), 1);
        var body = new Grid { RowSpacing = 5 }; body.RowDefinitions.Add(new() { Height = GridLength.Auto }); body.RowDefinitions.Add(new() { Height = new(3) }); body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var title = new Grid(); Columns(title, -1, 100);
        AddCell(title, Label(row.Name, 13), 0); AddCell(title, Label((row.IsPartial ? "≥ " : "") + row.DisplaySize, 12, right: true), 1);
        body.Children.Add(title);
        var bar = new Grid { Background = ThemeBrush("ShouDividerBrush"), Height = 3 };
        var fraction = Math.Clamp((double)row.AllocatedBytes / Math.Max(1, parentBytes), 0, 1);
        bar.ColumnDefinitions.Add(new() { Width = new(fraction, GridUnitType.Star) }); bar.ColumnDefinitions.Add(new() { Width = new(1 - fraction, GridUnitType.Star) });
        bar.Children.Add(new Border { Background = StoragePalette.Simple(row.Path, rendered!.Root), CornerRadius = new(2) });
        body.Children.Add(bar); Grid.SetRow(bar, 1);
        var count = Label(row.IsDirectory ? text.Format("%lld files", row.FileCount) : "", 10); ThemeResources.Apply(count, TextBlock.ForegroundProperty, "Foreground", "TextFillColorSecondaryBrush");
        body.Children.Add(count); Grid.SetRow(count, 2); AddCell(view, body, 2);
        if (row.IsDirectory) { var open = new Button { Content = "›", Style = ProductStyle("ShouToolbarButton"), Padding = new(0) }; open.Click += (_, _) => OpenDirectory(row.Path); AddCell(view, open, 3); AutomationProperties.SetName(open, text.Get("Open Directory") + " " + row.Name); }
        if (selection?.Contains(row.Path) == true) view.Background = ThemeBrush("ShouNavSelectionBrush");
        return view;
    }
    private Grid DetailedRow(StorageRow row, int depth, long parentBytes)
    {
        var view = TableGrid("ShouStorageNameWidth", "ShouStorageShareWidth", "ShouStorageSizeWidth", "ShouStorageSizeWidth", "ShouStorageFilesWidth", "ShouStorageModifiedWidth");
        view.Height = Metric("ShouStorageTableRowHeight");
        if (DirectoryTree.Items.Count % 2 != 0) view.Background = ThemeBrush("ShouTableStripeBrush");
        var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, Margin = new(depth * 12, 0, 0, 0) };
        var expand = new Button { Content = row.IsDirectory ? expandedPaths.Contains(row.Path) ? "⌄" : "›" : "", Width = 12, MinWidth = 0, MinHeight = 0, Padding = new(0), Height = Metric("ShouStorageTableRowHeight"), IsEnabled = row.IsDirectory, Style = ProductStyle("ShouToolbarButton") };
        expand.Click += (_, _) => { if (!expandedPaths.Add(row.Path)) expandedPaths.Remove(row.Path); RenderStorageResults(); };
        AutomationProperties.SetAutomationId(expand, "storage.expand." + row.Path.Value);
        name.Children.Add(expand); name.Children.Add(RowCheck(row)); name.Children.Add(FileIcon(row, Metric("ShouStorageTreeIconSize"))); name.Children.Add(Label(row.Name)); AddCell(view, name, 0);
        AddCell(view, ShareCell(row.AllocatedBytes, parentBytes), 1);
        AddCell(view, Label((row.IsPartial ? "≥ " : "") + row.DisplaySize, right: true), 2);
        AddCell(view, Label(StorageRow.FormatBytes(row.LogicalBytes), right: true), 3);
        AddCell(view, Label(row.FileCount.ToString("N0"), right: true), 4);
        AddCell(view, Label(row.ModifiedUtc?.ToLocalTime().ToString("g") ?? "—", right: true), 5);
        return view;
    }
    private FontIcon FileIcon(StorageRow row, double size)
    {
        var icon = new FontIcon { Glyph = row.IsDirectory ? "\uE8B7" : "\uE8A5", FontSize = size, VerticalAlignment = VerticalAlignment.Center };
        if (row.IsDirectory) icon.Foreground = new SolidColorBrush((global::Windows.UI.Color)Application.Current.Resources["ShouFolderIcon"]);
        else ThemeResources.Apply(icon, IconElement.ForegroundProperty, "Foreground", "TextFillColorSecondaryBrush");
        return icon;
    }
    private TextBlock Label(string value, double? size = null, bool right = false) => new() { Text = value, FontSize = size ?? Metric("ShouStorageTableFontSize"), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, TextAlignment = right ? TextAlignment.Right : TextAlignment.Left, Margin = new(2, 0, 2, 0) };
    private static void Columns(Grid view, params double[] widths) { foreach (var width in widths) view.ColumnDefinitions.Add(new() { Width = width < 0 ? new(1, GridUnitType.Star) : new(width) }); }
    private Grid TableGrid(params string[] widths) { var view = new Grid(); Columns(view, widths.Select(Metric).ToArray()); return view; }
    private static void AddCell(Grid view, FrameworkElement cell, int column) { Grid.SetColumn(cell, column); view.Children.Add(cell); }
    private Grid ShareCell(long bytes, long total)
    {
        var fraction = Math.Clamp((double)bytes / Math.Max(1, total), 0, 1);
        var cell = new Grid(); Columns(cell, -1);
        var fill = new Border { Background = new SolidColorBrush((global::Windows.UI.Color)Application.Current.Resources["ShouShareBar"]), HorizontalAlignment = HorizontalAlignment.Left };
        cell.SizeChanged += (_, _) => fill.Width = cell.ActualWidth * fraction;
        cell.Children.Add(fill); cell.Children.Add(Label(fraction.ToString("P1"), right: true)); return cell;
    }
    private Grid DirectoryHeader() => Header(new[] { "Name", "% of Parent", "Allocated", "Logical Size", "Files", "Modified" },
        "ShouStorageNameWidth", "ShouStorageShareWidth", "ShouStorageSizeWidth", "ShouStorageSizeWidth", "ShouStorageFilesWidth", "ShouStorageModifiedWidth");
    private Grid ExtensionHeader() => Header(new[] { "Type", "% of Scope", "Allocated", "Files", "Logical Size" },
        "ShouStorageExtensionWidth", "ShouStorageShareWidth", "ShouStorageSizeWidth", "ShouStorageFilesWidth", "ShouStorageSizeWidth");
    private Grid Header(string[] labels, params string[] widths)
    {
        var header = TableGrid(widths); header.Height = Metric("ShouStorageTableHeaderHeight"); header.Background = ThemeBrush("ShouTitlebarBrush");
        for (var index = 0; index < labels.Length; index++) AddCell(header, Label(text.Get(labels[index]), right: index > 0), index);
        return header;
    }
    private void RenderExtensionRows()
    {
        if (analysis is null || directory is null) return;
        var prior = updatingResults; updatingResults = true;
        try
        {
            ExtensionList.Items.Clear();
            var extensions = analysis.Extensions(directory); var total = extensions.Sum(type => type.AllocatedBytes);
            foreach (var type in extensions)
            {
                var view = TableGrid("ShouStorageExtensionWidth", "ShouStorageShareWidth", "ShouStorageSizeWidth", "ShouStorageFilesWidth", "ShouStorageSizeWidth");
                view.Tag = type; view.Height = Metric("ShouStorageTableRowHeight");
                if (ExtensionList.Items.Count % 2 != 0) view.Background = ThemeBrush("ShouTableStripeBrush");
                var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                title.Children.Add(new Border { Background = StoragePalette.Extension(type.Extension), Width = 10, Height = 10, VerticalAlignment = VerticalAlignment.Center });
                title.Children.Add(Label(type.Extension.Length == 0 ? text.Get("No Extension") : type.Extension));
                AddCell(view, title, 0); AddCell(view, ShareCell(type.AllocatedBytes, total), 1); AddCell(view, Label(type.DisplaySize, right: true), 2);
                AddCell(view, Label(type.Count.ToString("N0"), right: true), 3); AddCell(view, Label(StorageRow.FormatBytes(type.LogicalBytes), right: true), 4);
                ExtensionList.Items.Add(view);
                if (extensionFilter == type.Extension) ExtensionList.SelectedItem = view;
            }
            clearExtension.Visibility = extensionFilter is null ? Visibility.Collapsed : Visibility.Visible;
        }
        finally { updatingResults = prior; }
    }
    private void DirectoryKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (DirectoryTree.SelectedItem is not Grid { Tag: StorageRow row }) return;
        if (args.Key == global::Windows.System.VirtualKey.Enter && row.IsDirectory) OpenDirectory(row.Path);
        else if (args.Key == global::Windows.System.VirtualKey.Space) { selection?.Set(row, selection.Contains(row.Path) != true); RenderStorageResults(); UpdateSelection(); }
        else if (args.Key == global::Windows.System.VirtualKey.Right && row.IsDirectory) { expandedPaths.Add(row.Path); RenderStorageResults(); }
        else if (args.Key == global::Windows.System.VirtualKey.Left && row.IsDirectory) { expandedPaths.Remove(row.Path); RenderStorageResults(); }
        else return;
        args.Handled = true;
    }
    private void ClearStorageSelection(object sender, RoutedEventArgs args) { selection?.Clear(); RefreshResults(); }
    private void UpdateSelection()
    {
        RemoveButton.IsEnabled = Shou.Windows.Platform.WindowsCleanupMutation.PublicExecutionAvailable && !model.IsBusy && !HasActiveRemoval && selection is { Count: > 0 };
        SelectionDetails.Text = selection is { Count: > 0 } chosen ? text.Format("%lld items selected", chosen.Count) + " · " + StorageRow.FormatBytes(chosen.AllocatedBytes) : text.Get("Select files or folders to remove");
        ClearSelectionButton.Visibility = selection is { Count: > 0 } ? Visibility.Visible : Visibility.Collapsed;
    }
    private void UpdateMapHeading()
    {
        MapHeading.Text = focus?.Name ?? (directory == rendered?.Root ? text.Get("Measured Space") : directory?.Name ?? "");
        MapSize.Text = focus?.DisplaySize ?? TotalSize.Text;
    }
}
