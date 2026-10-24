using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Shou.Windows.App;

internal interface IPageChrome
{
    FrameworkElement Toolbar { get; }
}

internal static class PageChrome
{
    // A page owns its commands and lifetime; the window only hosts the active toolbar.
    public static FrameworkElement Detach(FrameworkElement toolbar, Panel owner)
    {
        owner.Children.Remove(toolbar);
        return toolbar;
    }
}

// Reuse a page's review controls in the expanded row without duplicating command state.
internal sealed class InlineDetails(FrameworkElement detail, Panel owner)
{
    private Expander? expanded;
    public void Show(Expander row)
    {
        if (ReferenceEquals(expanded, row)) return;
        Hide(); owner.Children.Remove(detail);
        expanded = row; row.Content = detail; detail.Visibility = Visibility.Visible;
    }
    public void Hide()
    {
        if (expanded is null) return;
        var previous = expanded; expanded = null;
        previous.Content = null; previous.IsExpanded = false;
        detail.Visibility = Visibility.Collapsed;
    }
}
