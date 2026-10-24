using System.Diagnostics;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

/// <summary>Shared stage layout. Only a known item denominator can supply a percentage.</summary>
public sealed class OperationProgressView : UserControl
{
    private readonly Border frame;
    private readonly StackPanel content, meter;
    private readonly Grid artworkSlot;
    private readonly Viewbox artworkScale;
    private readonly OperationActivityArtwork artwork = new();
    private readonly TextBlock title = new(), percentage = new(), path = new(), stopLabel = new();
    private readonly Button stop = new();
    private readonly ProgressBar progress = new() { Minimum = 0, Maximum = 1 };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1d / 24) };
    private readonly global::Windows.UI.ViewManagement.UISettings systemSettings = new();
    private readonly string stopText = new TextCatalog().Get("Stop");
    private readonly string stoppingText = new TextCatalog().Get("Stopping at a safe boundary…");
    private bool loaded, active, stopping;
    private double? fraction;

    public event RoutedEventHandler? StopClicked;
    public string StopAutomationId
    {
        get => AutomationProperties.GetAutomationId(stop);
        set => AutomationProperties.SetAutomationId(stop, value);
    }

    public OperationProgressView()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        Visibility = Visibility.Collapsed;
        artworkScale = new() { Child = artwork, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        artworkSlot = new() { Width = Number("ShouCleanupArtworkWidth"), HorizontalAlignment = HorizontalAlignment.Center };
        artworkSlot.Children.Add(artworkScale);
        title.TextAlignment = TextAlignment.Center; title.TextWrapping = TextWrapping.Wrap;
        title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        AutomationProperties.SetAutomationId(title, "operation.title");
        AutomationProperties.SetLiveSetting(title, AutomationLiveSetting.Polite);
        percentage.HorizontalAlignment = HorizontalAlignment.Center;
        percentage.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        AutomationProperties.SetAutomationId(percentage, "operation.percentage");
        progress.Height = progress.MinHeight = Number("ShouOperationMeterHeight");
        progress.Foreground = (Brush)Application.Current.Resources["ShouAccentBrush"];
        AutomationProperties.SetAutomationId(progress, "operation.progress");
        meter = new(); meter.Children.Add(percentage); meter.Children.Add(progress);
        path.Style = (Style)Application.Current.Resources["ShouMonoCaption"];
        path.MaxWidth = Number("ShouCleanupPathMaxWidth"); path.TextAlignment = TextAlignment.Center;
        path.TextTrimming = TextTrimming.CharacterEllipsis; path.MaxLines = 1;
        path.HorizontalAlignment = HorizontalAlignment.Stretch; path.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(path, "operation.current-path");
        stopLabel.MinWidth = Number("ShouOperationStopTextWidth"); stopLabel.TextAlignment = TextAlignment.Center;
        stop.Style = (Style)Application.Current.Resources["ShouBorderedButton"];
        stop.Content = stopLabel; stop.HorizontalAlignment = HorizontalAlignment.Center;
        stop.Click += (_, args) => StopClicked?.Invoke(this, args);
        content = new() { MaxWidth = Number("ShouOperationContentWidth"), VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Stretch };
        content.Children.Add(artworkSlot); content.Children.Add(title); content.Children.Add(meter);
        content.Children.Add(path); content.Children.Add(stop);
        frame = new() { Child = content }; Content = frame;
        SizeChanged += (_, _) => ApplyLayout();
        Loaded += (_, _) =>
        {
            loaded = true;
            systemSettings.AnimationsEnabledChanged += MotionPreferenceChanged;
            ApplyLayout(); RefreshMotion();
        };
        Unloaded += (_, _) =>
        {
            loaded = false; timer.Stop(); progress.IsIndeterminate = false;
            systemSettings.AnimationsEnabledChanged -= MotionPreferenceChanged;
        };
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => RefreshMotion());
        timer.Tick += (_, _) => artwork.Draw(Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency / Number("ShouCleanupMotionDuration") % 1, paused: false);
        ApplyLayout();
    }

    public void Update(bool isActive, string stageTitle, string symbol, string currentPath = "", double? completedFraction = null,
        bool stopRequested = false, bool canStop = true)
    {
        active = isActive; stopping = stopRequested;
        fraction = completedFraction is { } value && double.IsFinite(value) ? Math.Clamp(value, 0, 1) : null;
        title.Text = stopping ? stoppingText : stageTitle;
        AutomationProperties.SetName(progress, stageTitle);
        percentage.Text = fraction?.ToString("P0", CultureInfo.CurrentCulture) ?? "";
        percentage.Visibility = fraction is null ? Visibility.Collapsed : Visibility.Visible;
        progress.Value = fraction ?? 0;
        path.Text = string.IsNullOrEmpty(currentPath) ? " " : OperationProgressPresentation.CompactPath(currentPath);
        ToolTipService.SetToolTip(path, currentPath);
        AutomationProperties.SetName(path, currentPath);
        stopLabel.Text = stopping ? stoppingText : stopText;
        AutomationProperties.SetName(stop, stopLabel.Text);
        stop.IsEnabled = active && !stopping && canStop;
        artwork.SetSymbol(symbol);
        Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        RefreshMotion();
    }

    private void ApplyLayout()
    {
        var compact = ActualHeight < Number("ShouOperationCompactThreshold");
        double Size(string name) => Number("ShouOperation" + (compact ? "Compact" : "") + name);
        var horizontal = Size("HorizontalPadding"); var vertical = Size("VerticalPadding");
        frame.Padding = new(horizontal, vertical, horizontal, vertical);
        artworkSlot.Height = compact ? Number("ShouOperationCompactArtworkHeight") : Number("ShouCleanupArtworkHeight");
        var scale = compact ? Number("ShouOperationCompactArtworkScale") : 1;
        artworkScale.Width = Number("ShouCleanupArtworkWidth") * scale;
        artworkScale.Height = Number("ShouCleanupArtworkHeight") * scale;
        artworkSlot.Margin = new(0, 0, 0, Size("ArtworkBottom"));
        title.FontSize = Size("TitleSize"); percentage.FontSize = Size("PercentageSize");
        meter.Margin = new(0, Size("MeterTop"), 0, 0); meter.Spacing = Size("MeterSpacing");
        path.Height = Size("PathHeight"); path.Margin = new(0, Size("PathTop"), 0, 0);
        stop.Margin = new(0, Size("StopTop"), 0, 0);
    }

    private void MotionPreferenceChanged(global::Windows.UI.ViewManagement.UISettings sender, object args) =>
        DispatcherQueue.TryEnqueue(() => { if (loaded) RefreshMotion(); });

    private void RefreshMotion()
    {
        var animate = loaded && active && Visibility == Visibility.Visible && !stopping &&
            !AppearanceSettings.Preferences.ReduceMotion && systemSettings.AnimationsEnabled;
        progress.IsIndeterminate = fraction is null && animate;
        if (animate) timer.Start();
        else { timer.Stop(); artwork.Draw(0.35, paused: true); }
    }

    private static double Number(string name) => (double)Application.Current.Resources[name];
}
