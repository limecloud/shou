using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal sealed class ApplicationUpdatePanel : UserControl, IDisposable
{
    private readonly TextCatalog text = new();
    private readonly StackPanel panel = new();
    private CancellationTokenSource? operation;
    private ApplicationUpdateObservation? observation;
    private bool disposed, busy;
    private long generation;
    internal InstalledApplication Application { get; }

    internal ApplicationUpdatePanel(InstalledApplication application)
    {
        Application = application; panel.Spacing = (double)Microsoft.UI.Xaml.Application.Current.Resources["ShouItemSpacing"];
        Content = panel; Unloaded += (_, _) => Cancel(); Render();
    }

    internal void SetBusy(bool value) { busy = value; if (value) Cancel(); Render(); }

    private async Task Check()
    {
        if (disposed || busy || operation is not null) return;
        var request = ++generation; using var current = new CancellationTokenSource(); operation = current; observation = null; Render();
        try
        {
            var result = await WindowsApplicationUpdateCatalog.CreateChecker().CheckAsync(Application.Id, Application, current.Token);
            if (!disposed && request == generation && !current.IsCancellationRequested) observation = result;
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (!disposed && request == generation) observation = new(1, DateTimeOffset.UtcNow, Application.Id, Application.Name,
                Application.Version, ApplicationUpdateChecker.SourceFor(Application), null, ApplicationUpdateState.Unknown,
                error is ShouException { Code: "application_changed" } ? "application_changed" : "update_network_unavailable");
        }
        finally { if (!disposed && request == generation) { operation = null; Render(); } }
    }

    private void Render()
    {
        if (disposed) return; panel.Children.Clear(); Add("Application Updates");
        if (ApplicationUpdateChecker.SourceFor(Application) is not { } source)
        { Add("No supported catalog source. Use the app's own updater."); return; }
        Add("Checks the official stable release catalog for this app. No application list is uploaded and nothing is installed.");
        if (operation is not null)
        {
            Add("Checking catalog…"); var stop = new Button { Content = text.Get("Stop") }; stop.Click += (_, _) => Cancel(); panel.Children.Add(stop); return;
        }
        var check = new Button { Content = text.Get("Check Release Catalog"), IsEnabled = !busy }; check.Click += async (_, _) => await Check(); panel.Children.Add(check);
        if (observation is not { } value) return;
        Add(value.State switch { ApplicationUpdateState.NewerCatalogVersion => "Newer version in catalog", ApplicationUpdateState.SameCatalogVersion => "Matches catalog version",
            ApplicationUpdateState.InstalledVersionNewer => "Installed version is newer than the catalog", _ => "Could not verify" });
        if (value.CatalogVersion is { } version) panel.Children.Add(new TextBlock { Text = text.Get("Catalog Version") + ": " + version, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = text.Get("Observed at") + ": " + value.ObservedAt.ToLocalTime(), TextWrapping = TextWrapping.Wrap });
        if (value.Reason == "application_changed") Add("Application changed. Scan applications again before checking its catalog version.");
        if (value.State == ApplicationUpdateState.Unknown) Add("The catalog check could not finish. Try again.");
        var open = new HyperlinkButton { Content = text.Get("Open Official Update Page"), NavigateUri = new(source.OfficialPage), IsEnabled = !busy };
        panel.Children.Add(open);
        Add("Catalog versions do not verify installation compatibility. Use the app or its official updater to install updates.");
    }

    private void Add(string key) => panel.Children.Add(new TextBlock { Text = text.Get(key), TextWrapping = TextWrapping.Wrap });
    private void Cancel() { generation++; operation?.Cancel(); operation = null; Render(); }
    public void Dispose() { if (disposed) return; disposed = true; generation++; operation?.Cancel(); operation = null; }
}
