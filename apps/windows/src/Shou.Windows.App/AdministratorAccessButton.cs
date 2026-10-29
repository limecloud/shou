using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

/// <summary>Native UAC owns credential UI. Success only restores access; it never retries a mutation.</summary>
public sealed class AdministratorAccessButton : Button
{
    private readonly TextCatalog text = new();
    public AdministratorAccessButton()
    {
        Content = text.Get("Authorize…");
        Click += Authorize;
    }
    public static bool Required(string? code) => code is "permission_denied" or "authorization_required" or "scan_location_permissions" or "authorization_unavailable" or "authorization_cancelled" or "authorization_channel_lost";
    private async void Authorize(object sender, RoutedEventArgs args)
    {
        var root = XamlRoot;
        IsEnabled = false; Content = text.Get("Waiting for administrator authorization…");
        try
        {
            await WindowsSystemAuthorization.Shared.AuthorizeAdministratorAsync();
            Content = text.Get("Authorized for this session");
        }
        catch (Exception error)
        {
            Content = text.Get("Authorize…");
            var code = error is ShouException known ? known.Code : "authorization_unavailable";
            var dialog = new ContentDialog { XamlRoot = root, Title = text.Get("Administrator Access"),
                Content = ReviewText.Error(text, code), CloseButtonText = text.Get("Close"), DefaultButton = ContentDialogButton.Close };
            await dialog.ShowAsync();
        }
        finally { IsEnabled = true; }
    }
}
