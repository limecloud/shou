using System.Collections.Immutable;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;
using Microsoft.Windows.Storage.Pickers;

namespace Shou.Windows.App;

public sealed partial class StoragePageView : UserControl, IPageChrome, IDisposable
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this);

    private readonly TextCatalog text = new();
    private readonly StorageViewModel model = new(new HistoricalStorageScanner(new StorageScanner(new WindowsFileSystem()), new(WindowsRecordStore.ForCurrentUser())));
    private readonly nint windowHandle;
    private readonly bool largeFiles;
    private StorageAnalysis? analysis;
    private ScanSnapshot? rendered;
    private WindowsPath? root, directory;
    private readonly Stack<WindowsPath> back = new();
    private readonly Stack<WindowsPath> forward = new();
    private bool detailed;
    private bool navigating;
    private ImmutableArray<StorageRow> rows = [];
    private int offset;
    private const int PageSize = 200;
    private bool disposed;
    private Task? removal;
    private CancellationTokenSource? removalCancellation;
    public bool HasActiveRemoval => removal is { IsCompleted: false };
    public event EventHandler? BusyChanged;
    public FrameworkElement Toolbar => PageChrome.Detach(PageToolbar, PageLayout);

    public StoragePageView(nint windowHandle, bool largeFiles = false)
    {
        InitializeComponent();
        this.windowHandle = windowHandle; this.largeFiles = largeFiles;
        InitializeResultsLayout();
        StartIcon.Content = ProductIcon.Create(largeFiles ? "large" : "drive", (double)Application.Current.Resources[largeFiles ? "ShouStartIconSize" : "ShouStorageStartIconSize"]);
        StartTitle.FontSize = (double)Application.Current.Resources[largeFiles ? "ShouLargeFileTitleSize" : "ShouStorageStartTitleSize"];
        StartTitle.Text = text.Get(largeFiles ? "Find the files taking up the most space" : "Space Analysis");
        StartDescription.Text = text.Get(largeFiles ? "See large files across folders, then choose what to remove." : "Find what takes up space. Keep what matters.");
        var scanLabel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var scanIcon = ProductIcon.Create(largeFiles ? "large" : "drive", 16);
        ProductIcon.Select(scanIcon, "ShouActionTextBrush");
        scanLabel.Children.Add(scanIcon); scanLabel.Children.Add(new TextBlock { Text = text.Get("Start Scan"), VerticalAlignment = VerticalAlignment.Center });
        StartButton.Content = scanLabel;
        VolumeIcon.Content = ProductIcon.Create("drive", (double)Application.Current.Resources["ShouCompactIconSize"]);
        if (!largeFiles)
        {
            StartButton.Style = (Style)Application.Current.Resources["ShouScanButton"];
            StartButton.Content = text.Get("Start Scan");
            StartDescription.FontSize = (double)Application.Current.Resources["ShouStorageDescriptionSize"];
        }
        ChooseButton.Content = text.Get("Choose Folder…");
        WorkspaceVisuals.ArrangeLanding(StartContent, StartIcon, StartTitle, StartDescription, largeFiles ? "large-files" : "space");
        RescanButton.Content = text.Get("Rescan");
        CompareButton.Content = text.Get("Compare Analyses…");
        ReadOnlyNotice.Text = text.Get("Scanning reads file sizes. Nothing is selected or deleted automatically.");
        ScopeNotice.Text = text.Get("Sizes show measured allocated space. Partial coverage does not describe the entire disk. Storage browsing does not authorize deletion.");
        SearchBox.PlaceholderText = text.Get("Filter this folder"); ExtensionsHeading.Text = text.Get("File Extensions");
        PreviousButton.Content = text.Get("Previous"); NextButton.Content = text.Get("Next");
        AutomationProperties.SetName(InfoButton, text.Get("Information")); AutomationProperties.SetName(Volumes, text.Get("Scan Location"));
        AutomationProperties.SetName(UpButton, text.Get("Go Up")); AutomationProperties.SetName(BackButton, text.Get("Back")); AutomationProperties.SetName(ForwardButton, text.Get("Forward"));
        AutomationProperties.SetName(DirectoryTree, text.Get("Directory Tree"));
        AutomationProperties.SetName(SpaceMap, text.Get("Space Map")); AutomationProperties.SetName(SearchBox, text.Get("Search"));
        ToolTipService.SetToolTip(UpButton, text.Get("Up One Level")); ToolTipService.SetToolTip(BackButton, text.Get("Back")); ToolTipService.SetToolTip(ForwardButton, text.Get("Forward"));
        ViewLabel.Text = text.Get("View"); SimpleView.Content = text.Get("Simple"); DetailedView.Content = text.Get("Detailed");
        SimpleView.IsChecked = true;
        ClearSelectionButton.Content = text.Get("Clear Selection");
        RemoveButton.Content = text.Get("Delete Permanently");
        ToolTipService.SetToolTip(RemoveButton, text.Get("Permanent deletion cannot be undone."));
        AutomationProperties.SetHelpText(RemoveButton, text.Get("Permanent deletion cannot be undone."));
        var volumes = WindowsStorageVolumes.Read();
        Volumes.ItemsSource = volumes;
        foreach (var volume in volumes)
        {
            var item = new MenuFlyoutItem { Text = volume.Name, Tag = volume };
            item.Click += (_, _) => Volumes.SelectedItem = volume;
            VolumeMenu.Items.Add(item);
        }
        Volumes.SelectedItem = volumes.FirstOrDefault(value => value.Path.Value.StartsWith(System.IO.Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\", StringComparison.OrdinalIgnoreCase)) ?? volumes.FirstOrDefault();
        ViewLabel.Visibility = SimpleView.Visibility = DetailedView.Visibility = largeFiles ? Visibility.Collapsed : Visibility.Visible;
        model.PropertyChanged += Changed;
        Render();
    }
    private void SelectVolume(object sender, SelectionChangedEventArgs args)
    {
        if (Volumes.SelectedItem is not StorageVolume value) return;
        root = value.Path;
        VolumeLabel.Text = value.Name;
    }
    private async void ChooseFolder(object sender, RoutedEventArgs args)
    {
        if (model.IsBusy) return;
        try
        {
            var picker = new FolderPicker(Microsoft.UI.Win32Interop.GetWindowIdFromWindow(windowHandle));
            var folder = await picker.PickSingleFolderAsync();
            if (disposed || folder is null) return;
            root = WindowsPath.Parse(folder.Path); Volumes.SelectedItem = null;
            VolumeLabel.Text = root.Value; ChooseButton.Content = root.Value; StartButton.IsEnabled = true;
        }
        catch (Exception error) { Fail(error); }
    }
    private async void StartScan(object sender, RoutedEventArgs args)
    {
        if (root is null || model.IsBusy || disposed) return;
        offset = 0; analysis = null; rendered = null; directory = null; selection = null; focus = null; back.Clear(); forward.Clear();
        await model.ScanAsync(root, new(500_000, 64, TimeSpan.FromSeconds(180)));
    }
    private void StopScan(object sender, RoutedEventArgs args) => Cancel();
    private async void CompareAnalyses(object sender, RoutedEventArgs args)
    {
        if (model.IsBusy || HasActiveRemoval || rendered is null || directory is null) return;
        CompareButton.IsEnabled = false;
        try { await new StorageComparisonDialog(XamlRoot, rendered.Id, directory.RelativeTo(rendered.Root, true)).ShowAsync(); }
        finally { if (!disposed) CompareButton.IsEnabled = true; }
    }
    public void Cancel() { model.Cancel(); removalCancellation?.Cancel(); }
    public void CancelScan() => model.Cancel();
    private void Changed(object? sender, PropertyChangedEventArgs args) => Render();
    private void Render()
    {
        if (disposed) return;
        PageDiagnostics.Update(this, largeFiles ? "large" : "storage", model.State, model.ErrorCode, model.Snapshot?.Entries.Length);
        var busy = model.IsBusy;
        if (model.Snapshot is { } snapshot && rendered != snapshot)
        { rendered = snapshot; analysis = new(snapshot); selection = new(snapshot.Root); directory = snapshot.Root; RefreshResults(); }
        var hasResults = analysis is not null;
        PageToolbar.Visibility = !busy && hasResults ? Visibility.Visible : Visibility.Collapsed;
        LandingScroll.Visibility = StartContent.Visibility = !busy && !hasResults ? Visibility.Visible : Visibility.Collapsed;
        ResultContent.Visibility = !busy && hasResults ? Visibility.Visible : Visibility.Collapsed;
        RescanButton.IsEnabled = StartButton.IsEnabled = !busy && root is not null;
        ScanActivity.Update(busy, text.Get("Scanning…"), "drive", model.Progress?.CurrentPath.Value ?? root?.Value ?? "",
            stopRequested: model.StopRequested);
        FailureNotice.IsOpen = model.State is StoragePageState.Failed || model.State == StoragePageState.Cancelled && !hasResults;
        FailureNotice.Message = model.State == StoragePageState.Cancelled ? text.Get("Scan cancelled") : ReviewText.Error(text, model.ErrorCode);
        CoverageNotice.IsOpen = hasResults && model.State is StoragePageState.Partial or StoragePageState.Cancelled;
        CoverageNotice.Message = text.Get(model.State == StoragePageState.Cancelled ? "Scan cancelled" : "Some locations could not be read. Sizes show only measured data.");
    }
    private void RefreshResults()
    {
        if (analysis is null || directory is null) return;
        rows = largeFiles ? analysis.LargeFiles(SearchBox.Text) : SortedRows(directory, SearchBox.Text);
        offset = Math.Min(offset, Math.Max(0, (rows.Length - 1) / PageSize * PageSize));
        CurrentPath.Text = directory.Value; ToolTipService.SetToolTip(CurrentPath, directory.Value);
        RenderBreadcrumb();
        TotalSize.Text = StorageRow.FormatBytes(analysis.Directory(directory).Sum(row => row.AllocatedBytes));
        UpButton.IsEnabled = !largeFiles && directory != rendered!.Root;
        BackButton.IsEnabled = !largeFiles && back.Count > 0;
        ForwardButton.IsEnabled = !largeFiles && forward.Count > 0;
        SimpleView.IsChecked = !detailed; DetailedView.IsChecked = detailed;
        ItemCount.Text = text.Format("%lld matching items", rows.Length);
        PreviousButton.IsEnabled = offset > 0; NextButton.IsEnabled = offset + PageSize < rows.Length;
        PreviousButton.Visibility = NextButton.Visibility = rows.Length > PageSize ? Visibility.Visible : Visibility.Collapsed;
        StorageResultsHost.Visibility = largeFiles ? Visibility.Collapsed : Visibility.Visible;
        LargeFilesList.Visibility = largeFiles ? Visibility.Visible : Visibility.Collapsed;
        if (largeFiles) LargeFilesList.ItemsSource = rows.Skip(offset).Take(PageSize).ToArray();
        else RenderStorageResults();
        UpdateSelection();
    }
    private void InspectLargeFile(object sender, SelectionChangedEventArgs args)
    {
        if (LargeFilesList.SelectedItem is not StorageRow row || HasActiveRemoval) return;
        Inspect(row); UpdateSelection();
    }
    private void LoadLargeCheck(object sender, RoutedEventArgs args)
    {
        if (sender is not CheckBox { Tag: StorageRow row } check) return;
        check.IsChecked = selection?.Contains(row.Path) == true; check.IsEnabled = selection?.CanSelect(row) == true && !HasActiveRemoval;
        AutomationProperties.SetName(check, row.Path.Value);
    }
    private void ToggleLargeFile(object sender, RoutedEventArgs args)
    {
        if (sender is not CheckBox { Tag: StorageRow row } check || HasActiveRemoval) return;
        selection?.Set(row, check.IsChecked == true); Inspect(row); UpdateSelection();
    }
    private async void RemoveSelected(object sender, RoutedEventArgs args)
    {
        if (!WindowsCleanupMutation.PublicExecutionAvailable || disposed || model.IsBusy || HasActiveRemoval || rendered is not { } snapshot || selection is not { Count: > 0 } selected) return;
        var paths = selected.Items.Select(row => row.Path).ToImmutableArray();
        using var cancellation = new CancellationTokenSource(); removalCancellation = cancellation;
        var completion = new TaskCompletionSource(); removal = completion.Task;
        ResultContent.IsHitTestVisible = PageToolbar.IsHitTestVisible = false;
        BusyChanged?.Invoke(this, EventArgs.Empty);
        using var diagnostic = OperationDiagnostics.Start("ui.storage.remove");
        try
        {
            var operations = new NativeReviewOperations();
            var plan = await operations.CreateStoragePlanAsync(snapshot, paths, cancellation.Token);
            var confirmation = WinUICleanupConfirmation.Create(this, plan);
            var result = await operations.ExecuteAsync(plan.Id, confirmation, cancellation.Token);
            diagnostic.Complete(result.State.ToString().ToLowerInvariant(), result.Items.Length);
            var removed = plan.Items.Where(item => result.Items.Any(value => value.ItemId == item.Id && value.State == CleanupItemState.Purged)).Select(item => item.Path).ToArray();
            rendered = snapshot with { Entries = snapshot.Entries.Where(value => !removed.Any(path => value.Entry.Path.IsWithin(path, caseSensitive: true))).ToImmutableArray() };
            analysis = new(rendered); selection?.Clear(); RefreshResults();
            FailureNotice.Severity = result.State == CleanupExecutionState.Completed ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
            FailureNotice.Message = ReviewText.ExecutionState(text, result.State) + ", " + result.Id + Environment.NewLine +
                string.Join(Environment.NewLine, result.Items.Where(item => item.State != CleanupItemState.Purged).Select(item => ReviewText.ItemState(text, item.State) + ", " + ReviewText.Error(text, item.Reason)));
            FailureNotice.IsOpen = true;
        }
        catch (Exception error) { diagnostic.Fail(error); Fail(error); }
        finally
        {
            completion.TrySetResult(); removal = null; removalCancellation = null;
            ResultContent.IsHitTestVisible = PageToolbar.IsHitTestVisible = true;
            UpdateSelection(); BusyChanged?.Invoke(this, EventArgs.Empty);
        }
    }
    private void Inspect(StorageRow row)
    {
        focus = row;
        UpdateMapHeading();
        DrawMap();
        ToolTipService.SetToolTip(SelectionDetails, row.Path.Value + ", " + row.DisplaySize);
    }
    private void OpenDirectory(WindowsPath path)
    {
        if (!navigating && directory is { } current && current != path) { back.Push(current); forward.Clear(); }
        directory = path; focus = null; expandedPaths.Clear(); offset = 0; SearchBox.Text = ""; RefreshResults();
    }
    private void GoBack(object sender, RoutedEventArgs args) => Travel(back, forward);
    private void GoForward(object sender, RoutedEventArgs args) => Travel(forward, back);
    private void Travel(Stack<WindowsPath> from, Stack<WindowsPath> to)
    {
        if (directory is not { } current || from.Count == 0) return;
        to.Push(current);
        navigating = true;
        try { OpenDirectory(from.Pop()); }
        finally { navigating = false; }
    }
    private void GoUp(object sender, RoutedEventArgs args) { if (directory?.Parent is { } parent && rendered is { } value && parent.IsWithin(value.Root, caseSensitive: true)) OpenDirectory(parent); }
    private void ChangeViewMode(object sender, RoutedEventArgs args)
    {
        if (sender is not ToggleButton { Tag: string tag }) return;
        detailed = tag == "detailed";
        RefreshResults();
        DrawMap();
    }
    private void RenderBreadcrumb()
    {
        Breadcrumb.Children.Clear();
        if (directory is null || rendered is null) return;
        var chain = new Stack<WindowsPath>();
        for (var path = directory; path is { } current && current.IsWithin(rendered.Root, caseSensitive: true); path = current == rendered.Root ? null : current.Parent)
            chain.Push(current);
        while (chain.Count > 0)
        {
            var path = chain.Pop();
            if (Breadcrumb.Children.Count > 0)
            {
                var separator = new FontIcon { Glyph = "\uE76C", FontSize = 10, VerticalAlignment = VerticalAlignment.Center };
                ThemeResources.Apply(separator, IconElement.ForegroundProperty, "Foreground", "TextFillColorTertiaryBrush");
                Breadcrumb.Children.Add(separator);
            }
            var label = path == rendered.Root ? VolumeLabel.Text : path.Name;
            var button = new Button { Content = label, Tag = path, Padding = new Thickness(4, 0, 4, 0), Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(0, 0, 0, 0)), BorderThickness = new Thickness(0) };
            ThemeResources.Apply(button, Control.ForegroundProperty, "Foreground", "ShouAccentBrush");
            button.Click += (_, _) => { if (button.Tag is WindowsPath target) OpenDirectory(target); };
            AutomationProperties.SetName(button, path.Value);
            Breadcrumb.Children.Add(button);
        }
    }
    private void FilterChanged(object sender, TextChangedEventArgs args) { offset = 0; RefreshResults(); }
    private void Previous(object sender, RoutedEventArgs args) { offset = Math.Max(0, offset - PageSize); RefreshResults(); }
    private void Next(object sender, RoutedEventArgs args) { if (offset + PageSize < rows.Length) offset += PageSize; RefreshResults(); }
    private void MapSizeChanged(object sender, SizeChangedEventArgs args) => DrawMap();
    private void Fail(Exception error) { NativeDiagnostics.Write(error); if (!disposed) { FailureNotice.Message = ReviewText.Error(text, error is ShouException known ? known.Code : null); FailureNotice.IsOpen = true; } }
    public void Dispose() { if (disposed) return; disposed = true; model.PropertyChanged -= Changed; model.Dispose(); GC.SuppressFinalize(this); }
}

