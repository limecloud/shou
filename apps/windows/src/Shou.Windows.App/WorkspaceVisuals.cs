using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal static class WorkspaceVisuals
{
    public static Image Artwork(string name, double width = 400, double height = 310)
    {
        var image = new Image { Source = new BitmapImage(new Uri("ms-appx:///Assets/Illustrations/" + name + ".png")),
            Width = width, Height = height, Stretch = Stretch.Uniform, IsHitTestVisible = false };
        AutomationProperties.SetAccessibilityView(image, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return image;
    }

    public static FrameworkElement Heading(string title, string subtitle, string artwork)
    {
        var inset = (double)Application.Current.Resources["ShouWorkspaceInset"];
        var grid = new Grid { Margin = new Thickness(inset, 8, inset, 8), ColumnSpacing = 20 };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel { Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = title, FontSize = (double)Application.Current.Resources["ShouSummaryFigureSize"], FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var detail = new TextBlock { Text = subtitle, TextWrapping = TextWrapping.Wrap };
        ThemeResources.Apply(detail, TextBlock.ForegroundProperty, "Foreground", "TextFillColorSecondaryBrush");
        words.Children.Add(detail);
        var picture = Artwork(artwork, 84, 56); Grid.SetColumn(picture, 1);
        grid.Children.Add(words); grid.Children.Add(picture);
        return grid;
    }

    // Reparent existing commands, keeping their handlers, scope controls and automation IDs.
    public static void ArrangeLanding(StackPanel content, ContentControl icon, TextBlock title, TextBlock description, string artwork)
    {
        var children = content.Children.Cast<UIElement>().ToArray();
        content.Children.Clear();
        var words = new StackPanel { Spacing = 20, MaxWidth = 470, VerticalAlignment = VerticalAlignment.Center };
        foreach (var child in children.Where(child => !ReferenceEquals(child, icon)))
        {
            if (child is FrameworkElement element) element.HorizontalAlignment = HorizontalAlignment.Left;
            words.Children.Add(child);
        }
        title.FontSize = (double)Application.Current.Resources["ShouHeroCompactTitleSize"];
        ThemeResources.Apply(title, TextBlock.ForegroundProperty, "Foreground", "TextFillColorPrimaryBrush");
        title.HorizontalAlignment = HorizontalAlignment.Left; title.TextAlignment = TextAlignment.Left;
        title.TextWrapping = TextWrapping.Wrap;
        description.HorizontalAlignment = HorizontalAlignment.Left; description.TextAlignment = TextAlignment.Left;
        icon.Content = Artwork(artwork);
        var grid = new Grid { ColumnSpacing = 28, MaxWidth = 1080, HorizontalAlignment = HorizontalAlignment.Center };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(400) });
        Grid.SetColumn(icon, 1); grid.Children.Add(words); grid.Children.Add(icon);
        content.MaxWidth = (double)Application.Current.Resources["ShouHomeMaxWidth"]; content.Margin = new Thickness(42, 28, 42, 28);
        content.HorizontalAlignment = HorizontalAlignment.Stretch;
        content.Children.Add(grid);
        // Reduce decorative art at the minimum window size while preserving the actual controls.
        ScrollViewer? viewport = null;
        void FitLanding(object? sender, SizeChangedEventArgs? args)
        {
            grid.Width = Math.Min(grid.MaxWidth, content.ActualWidth);
            var compact = content.ActualWidth < 1000 ||
                viewport is { ActualHeight: > 0 } && viewport.ActualHeight < (double)Application.Current.Resources["ShouHomeCompactHeightBreakpoint"];
            words.Spacing = compact ? (double)Application.Current.Resources["ShouHomeCompactSpacing"] : 20;
            var inset = compact ? (double)Application.Current.Resources["ShouHomeCompactInset"] : 28;
            content.Margin = new Thickness(inset);
            var width = compact ? (double)Application.Current.Resources["ShouHomeCompactArtworkWidth"] : 400;
            grid.ColumnDefinitions[1].Width = new GridLength(width);
            if (icon.Content is Image image)
            {
                image.Width = width;
                image.Height = compact ? (double)Application.Current.Resources["ShouHomeCompactArtworkHeight"] : 310;
            }
        }
        content.SizeChanged += FitLanding;
        content.Loaded += (_, _) =>
        {
            if (viewport is not null) viewport.SizeChanged -= FitLanding;
            for (DependencyObject? parent = VisualTreeHelper.GetParent(content); parent is not null; parent = VisualTreeHelper.GetParent(parent))
            {
                if (parent is ScrollViewer scroll) { viewport = scroll; break; }
            }
            if (viewport is not null) viewport.SizeChanged += FitLanding;
            FitLanding(null, null);
        };
        content.Unloaded += (_, _) =>
        {
            if (viewport is not null) viewport.SizeChanged -= FitLanding;
            viewport = null;
        };
    }

    public static FrameworkElement Landing(TextCatalog text, string title, string subtitle, string artwork, string action,
        string automationId, RoutedEventHandler clicked)
    {
        var content = new StackPanel { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Center };
        var icon = new ContentControl(); var heading = new TextBlock { Text = text.Get(title) };
        var description = new TextBlock { Text = text.Get(subtitle), TextWrapping = TextWrapping.Wrap };
        ThemeResources.Apply(description, TextBlock.ForegroundProperty, "Foreground", "TextFillColorSecondaryBrush");
        var start = new Button { Content = text.Get(action), Style = (Style)Application.Current.Resources["ShouScanButton"] };
        start.Click += clicked; AutomationProperties.SetAutomationId(start, automationId);
        content.Children.Add(icon); content.Children.Add(heading); content.Children.Add(description); content.Children.Add(start);
        ArrangeLanding(content, icon, heading, description, artwork);
        return new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalContentAlignment = VerticalAlignment.Center };
    }

    public static FrameworkElement Destinations(TextCatalog text, Action<string> navigate)
    {
        var grid = new Grid { ColumnSpacing = 16, Margin = new Thickness(0, 12, 0, 0) };
        var entries = new[]
        {
            ("applications", "Apps & Projects", "A clearer view of apps and build outputs.", "applications"),
            ("storage", "Space Analysis", "Find the files taking up the most room.", "space"),
            ("configuration", "Your Cleanup Rules", "A routine that fits your own folders.", "rules")
        };
        for (var index = 0; index < entries.Length; index++)
        {
            var (page, title, subtitle, artwork) = entries[index];
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            var content = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            content.Children.Add(new TextBlock { Text = text.Get(title), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap });
            var detail = new Grid { ColumnSpacing = 12 };
            detail.ColumnDefinitions.Add(new ColumnDefinition());
            detail.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var description = new TextBlock { Text = text.Get(subtitle), TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center };
            ThemeResources.Apply(description, TextBlock.ForegroundProperty, "Foreground", "TextFillColorSecondaryBrush");
            description.FontSize = (double)Application.Current.Resources["ShouCaptionFontSize"];
            content.Children.Add(description);
            detail.Children.Add(content);
            var size = (double)Application.Current.Resources["ShouHomeCardArtworkSize"];
            var picture = Artwork(artwork, size, size); Grid.SetColumn(picture, 1); detail.Children.Add(picture);
            var button = new Button { Content = detail, Padding = new Thickness(16), HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch, MinHeight = (double)Application.Current.Resources["ShouHomeCardHeight"],
                CornerRadius = (CornerRadius)Application.Current.Resources["ShouHomeCardRadius"] };
            ThemeResources.Apply(button, Control.BackgroundProperty, "Background", "ShouSurfaceBrush");
            ThemeResources.Apply(button, Control.BorderBrushProperty, "BorderBrush", "ShouDividerBrush");
            ThemeResources.Apply(button, Control.ForegroundProperty, "Foreground", "TextFillColorPrimaryBrush");
            AutomationProperties.SetAutomationId(button, "smart.destination." + page);
            button.Click += (_, _) => navigate(page);
            Grid.SetColumn(button, index); grid.Children.Add(button);
        }
        return grid;
    }
}
