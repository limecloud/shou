using System.Globalization;
using Microsoft.UI.Xaml;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal static class AppearanceSettings
{
    private static readonly CultureInfo SystemCulture = CultureInfo.CurrentUICulture;
    public static bool AnimationsEnabled => !Preferences.ReduceMotion && new global::Windows.UI.ViewManagement.UISettings().AnimationsEnabled;
    public static DesktopPreferences Preferences { get; private set; } = new();
    public static AppearanceSettingsValue Current => new(Preferences.Theme switch
    { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default }, Preferences.ReduceMotion);
    public static async Task LoadAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try { Preferences = await new WindowsDesktopPreferences(WindowsRecordStore.ForCurrentUser()).ReadAsync(timeout.Token); ApplyLanguage(); }
        catch (Exception error) { NativeDiagnostics.Write(error); }
    }
    public static async Task SaveAsync(DesktopPreferences value)
    {
        await new WindowsDesktopPreferences(WindowsRecordStore.ForCurrentUser()).SaveAsync(value, CancellationToken.None);
        Preferences = value;
        ApplyLanguage();
    }
    private static void ApplyLanguage()
    {
        var culture = Preferences.Language == "system" ? SystemCulture : CultureInfo.GetCultureInfo(Preferences.Language);
        CultureInfo.CurrentUICulture = CultureInfo.DefaultThreadCurrentUICulture = culture;
    }
}

internal sealed record AppearanceSettingsValue(ElementTheme Theme, bool ReduceMotion);
