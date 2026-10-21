using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed class ProgressPathTextBlock : TextBlock
{
    public static readonly DependencyProperty FullPathProperty = DependencyProperty.Register(
        nameof(FullPath), typeof(string), typeof(ProgressPathTextBlock),
        new PropertyMetadata("", (target, _) => ((ProgressPathTextBlock)target).UpdateText()));

    public string FullPath
    {
        get => (string)GetValue(FullPathProperty);
        set => SetValue(FullPathProperty, value);
    }

    public ProgressPathTextBlock()
    {
        SizeChanged += (_, _) => UpdateText();
        Loaded += (_, _) => UpdateText();
    }

    static ProgressPathTextBlock()
    {
        foreach (var property in new[] { FontSizeProperty, FontFamilyProperty, FontStyleProperty,
            FontWeightProperty, FontStretchProperty, FlowDirectionProperty })
            property.OverrideMetadata(typeof(ProgressPathTextBlock), new FrameworkPropertyMetadata(
                (target, _) => ((ProgressPathTextBlock)target).UpdateText()));
    }

    private void UpdateText()
    {
        var available = Math.Max(0, ActualWidth - Padding.Left - Padding.Right);
        var typeface = new Typeface(FontFamily, FontStyle, FontWeight, FontStretch);
        var pixelsPerDip = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        Text = ProgressPresentation.FitPath(FullPath ?? "", value =>
            new FormattedText(value, CultureInfo.CurrentUICulture, FlowDirection,
                typeface, FontSize, Foreground, pixelsPerDip).WidthIncludingTrailingWhitespace <= available);
    }
}
