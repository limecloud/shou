using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal sealed class DesktopUpdateDialog : ContentDialog
{
    private readonly TextCatalog text = new();
    private readonly CancellationTokenSource cancellation = new();
    private readonly StackPanel content = new() { Spacing = 12 };
    private DesktopUpdate? update;

    internal DesktopUpdateDialog(XamlRoot root)
    {
        XamlRoot = root; FontSize = (double)Application.Current.Resources["ShouBodyFontSize"];
        Title = text.Get("Software Update");
        CloseButtonText = text.Get("Close");
        DefaultButton = ContentDialogButton.Close;
        Content = content;
        AutomationProperties.SetAutomationId(this, "updates.dialog");
        Opened += async (_, _) => await CheckAsync();
        Closed += (_, _) => { cancellation.Cancel(); cancellation.Dispose(); };
        PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (update is not { IsNewer: true } release) return;
            try
            {
                if (await global::Windows.System.Launcher.LaunchUriAsync(release.DownloadUrl)) Hide();
                else AddText("The download page could not be opened. Try again.");
            }
            catch (Exception) { AddText("The download page could not be opened. Try again."); }
        };
        SecondaryButtonClick += async (_, args) => { args.Cancel = true; await CheckAsync(); };
    }

    private async Task CheckAsync()
    {
        update = null; PrimaryButtonText = ""; SecondaryButtonText = "";
        CloseButtonText = text.Get("Close");
        content.Children.Clear();
        AddText("Checking for updates…");
        content.Children.Add(new ProgressRing { IsActive = true, HorizontalAlignment = HorizontalAlignment.Left });
        try
        {
            var architecture = RuntimeInformation.OSArchitecture switch { Architecture.X64 => "x64", Architecture.Arm64 => "arm64", _ => "unsupported" };
            var current = typeof(DesktopUpdateDialog).Assembly.GetName().Version!.ToString(3);
            var result = await new WindowsDesktopUpdates().CheckAsync(current, architecture, cancellation.Token);
            if (cancellation.IsCancellationRequested) return;
            update = result;
            content.Children.Clear();
            content.Children.Add(WorkspaceVisuals.Artwork("brand-icon", 64, 64));
            AddText(result.IsNewer ? "A new version of Shou is available." : "You’re up to date.");
            AddText(text.Get("Current version") + ": " + current, translate: false);
            if (!result.IsNewer) return;
            AddText(text.Get("Latest version") + ": " + result.Version, translate: false);
            AddText("Release Notes");
            content.Children.Add(new ScrollViewer { MaxHeight = 240, Content = new TextBlock
            {
                Text = string.IsNullOrWhiteSpace(result.Notes) ? text.Get("No release notes were provided.") : result.Notes,
                TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true
            }});
            AddText("This portable version updates manually. Download the new version, quit Shou, then replace its folder. Your local data stays in place.");
            PrimaryButtonText = text.Get("Download Update");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception)
        {
            if (cancellation.IsCancellationRequested) return;
            content.Children.Clear();
            AddText("Could not check for updates. Check your connection and try again.");
            SecondaryButtonText = text.Get("Retry");
        }
    }

    private void AddText(string value, bool translate = true) => content.Children.Add(new TextBlock
    { Text = translate ? text.Get(value) : value, TextWrapping = TextWrapping.Wrap });
}
