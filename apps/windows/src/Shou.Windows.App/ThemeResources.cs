using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Markup;

namespace Shou.Windows.App;

/// <summary>Keep theme references live on code-created elements, just as XAML does.</summary>
internal static class ThemeResources
{
    private sealed class References(Style? original)
    {
        public Style? Original { get; } = original;
        public Dictionary<string, string> Values { get; } = [];
    }

    private static readonly ConditionalWeakTable<FrameworkElement, References> references = new();

    public static void Apply(FrameworkElement element, DependencyProperty property, string name, string resource)
    {
        element.ClearValue(property);
        var state = references.GetValue(element, value => new(value.Style));
        if (state.Values.TryGetValue(name, out var current) && current == resource) return;
        state.Values[name] = resource;
        var setters = string.Concat(state.Values.Select(pair =>
            "<Setter Property='" + pair.Key + "' Value='{ThemeResource " + pair.Value + "}' />"));
        var style = (Style)XamlReader.Load("<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='" +
            element.GetType().Name + "'>" + setters + "</Style>");
        style.BasedOn = state.Original;
        element.Style = style;
    }
}
