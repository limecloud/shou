using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;
using Windows.ApplicationModel.DataTransfer;

namespace Shou.Windows.App;

// Viewing the report does not open a record lease or initialize the runtime log.
internal sealed class UserDiagnosticsDialog : ContentDialog
{
    private readonly TextCatalog text = new();
    private readonly UserDiagnosticsViewModel model;
    private readonly StackPanel content = new();

    internal UserDiagnosticsDialog(XamlRoot root)
    {
        XamlRoot = root;
        Title = text.Get("Diagnostics");
        PrimaryButtonText = text.Get("Copy Report");
        SecondaryButtonText = text.Get("Retry");
        CloseButtonText = text.Get("Close");
        DefaultButton = ContentDialogButton.Close;
        Resources["ContentDialogMaxWidth"] = Application.Current.Resources["ShouDiagnosticsSheetWidth"];
        content.Spacing = (double)Application.Current.Resources["ShouPageSpacing"];
        Content = new ScrollViewer { Content = content, MaxHeight = (double)Application.Current.Resources["ShouDiagnosticsSheetHeight"], HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        model = new(new WindowsUserDiagnostics(typeof(UserDiagnosticsDialog).Assembly.GetName().Version?.ToString(3) ?? "development"));
        model.PropertyChanged += (_, _) => Render();
        Opened += async (_, _) => await model.RefreshAsync();
        PrimaryButtonClick += (_, args) =>
        {
            args.Cancel = true;
            if (model.Report is not { } report) return;
            try { var package = new DataPackage(); package.SetText(report.Text(text.Get)); Clipboard.SetContent(package); }
            catch (Exception) { AddText("Copy failed. Try again."); }
        };
        SecondaryButtonClick += async (_, args) => { args.Cancel = true; await model.RefreshAsync(); };
        Closed += (_, _) => model.Dispose();
        Unloaded += (_, _) => model.Dispose();
        AutomationProperties.SetAutomationId(this, "diagnostics.report");
        Render();
    }

    private void Render()
    {
        content.Children.Clear();
        IsPrimaryButtonEnabled = model.Report is not null && !model.IsBusy;
        IsSecondaryButtonEnabled = !model.IsBusy;
        AddText("This report contains bounded system facts, not personal paths or file contents. Nothing is uploaded.");
        if (model.IsBusy) { content.Children.Add(new ProgressRing { IsActive = true }); return; }
        if (model.ErrorCode is not null) { AddText("Diagnostics could not finish. Check the local data location and try again."); return; }
        if (model.Report is not { } report) return;
        foreach (var check in report.Checks)
        {
            AddText(check.Title);
            AddText(DiagnosticReport.StateTitle(check.State));
            AddText(check.Explanation);
            if (check.NextStep is { } next) AddText(next);
        }
        content.Children.Add(new Expander { Header = text.Get("Report"), HorizontalAlignment = HorizontalAlignment.Stretch,
            Content = new TextBlock { Text = report.Text(text.Get), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } });
    }

    private void AddText(string key, bool translate = true) => content.Children.Add(new TextBlock
    { Text = translate ? text.Get(key) : key, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
}
