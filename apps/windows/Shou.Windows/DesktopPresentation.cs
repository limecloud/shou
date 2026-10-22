using System.ComponentModel;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Shou.Windows;

/// <summary>Application appearance follows Windows accessibility settings without changing them.</summary>
public sealed class DesktopPresentation : ObservableObject
{
    public static DesktopPresentation Current { get; } = new();
    private DesktopPreferences preferences = new();
    private bool reducedMotion;
    public bool AnimateIndicators => !reducedMotion;
    public bool ReducedMotion => reducedMotion;

    private DesktopPresentation() => SystemParameters.StaticPropertyChanged += WindowsPreferenceChanged;

    private void WindowsPreferenceChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (Application.Current is { } app) app.Dispatcher.InvokeAsync(Refresh);
    }

    public void Apply(DesktopPreferences value) { preferences = value; Refresh(); }

    // WPF's Fluent ThemeMode API is also used by App.xaml. Keep its preview
    // diagnostic scoped to this adapter while retaining all other warnings.
#pragma warning disable WPF0001
    private void Refresh()
    {
        var reduced = preferences.UsesReducedMotion(SystemParameters.ClientAreaAnimation, SystemParameters.HighContrast);
        if (SetProperty(ref reducedMotion, reduced, nameof(ReducedMotion))) OnPropertyChanged(nameof(AnimateIndicators));
        if (Application.Current is not { } app) return;
        app.ThemeMode = SystemParameters.HighContrast ? ThemeMode.System : preferences.Appearance switch
        {
            "light" => ThemeMode.Light, "dark" => ThemeMode.Dark, _ => ThemeMode.System
        };
    }
#pragma warning restore WPF0001
}
