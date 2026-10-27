using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

/// <summary>Module selection only; inventory starts inside the selected module.</summary>
internal sealed class ToolboxPage : UserControl
{
    internal ToolboxPage(Action<string> navigate)
    {
        var text = new TextCatalog();
        var inset = (double)Application.Current.Resources["ShouWorkspaceInset"];
        var spacing = (double)Application.Current.Resources["ShouSectionSpacing"];
        var content = new StackPanel { Spacing = spacing, MaxWidth = (double)Application.Current.Resources["ShouHomeMaxWidth"],
            Margin = new Thickness(inset), HorizontalAlignment = HorizontalAlignment.Stretch };
        content.Children.Add(new TextBlock { Text = text.Get("Toolbox"),
            FontSize = (double)Application.Current.Resources["ShouToolTitleSize"], FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var modules = new Grid { ColumnSpacing = spacing };
        modules.ColumnDefinitions.Add(new()); modules.ColumnDefinitions.Add(new());
        var entries = new[] {
            ("ai-tools", "AI Workbench", "AI apps, configuration and extensions.", "rules"),
            ("developer-tools", "Developer Tools", "Manage services and development tools.", "projects")
        };
        for (var index = 0; index < entries.Length; index++)
        {
            var (destination, title, detail, artwork) = entries[index];
            var body = new StackPanel { Spacing = spacing };
            body.Children.Add(WorkspaceVisuals.Artwork(artwork,
                (double)Application.Current.Resources["ShouHomeCompactArtworkWidth"],
                (double)Application.Current.Resources["ShouHomeCompactArtworkHeight"]));
            var label = new Grid { ColumnSpacing = 12 };
            label.ColumnDefinitions.Add(new()); label.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var words = new StackPanel { Spacing = 8 };
            words.Children.Add(new TextBlock { Text = text.Get(title), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            var description = new TextBlock { Text = text.Get(detail), TextWrapping = TextWrapping.Wrap };
            ThemeResources.Apply(description, TextBlock.ForegroundProperty, "Foreground", "TextFillColorSecondaryBrush");
            words.Children.Add(description); label.Children.Add(words);
            var arrow = new TextBlock { Text = "↗", VerticalAlignment = VerticalAlignment.Center };
            ThemeResources.Apply(arrow, TextBlock.ForegroundProperty, "Foreground", "ShouAccentBrush");
            Grid.SetColumn(arrow, 1); label.Children.Add(arrow); body.Children.Add(label);
            var button = new Button { Content = body, Padding = new Thickness(inset), HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch, BorderThickness = new Thickness(0.5),
                CornerRadius = (CornerRadius)Application.Current.Resources["ShouCardRadius"] };
            ThemeResources.Apply(button, Control.BackgroundProperty, "Background", "ShouSurfaceBrush");
            ThemeResources.Apply(button, Control.BorderBrushProperty, "BorderBrush", "ShouDividerBrush");
            ThemeResources.Apply(button, Control.ForegroundProperty, "Foreground", "TextFillColorPrimaryBrush");
            AutomationProperties.SetAutomationId(button, "tools.open." + destination);
            button.Click += (_, _) => navigate(destination);
            Grid.SetColumn(button, index); modules.Children.Add(button);
        }
        content.Children.Add(modules);
        Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalContentAlignment = VerticalAlignment.Center };
        FontSize = (double)Application.Current.Resources["ShouBodyFontSize"];
        AutomationProperties.SetAutomationId(this, "tools.welcome");
    }
}
