using System.Windows;
using System.Windows.Controls;

namespace Shou.Windows;

public partial class ScanLocationsView : UserControl
{
    public ScanLocationsView()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            if (Window.GetWindow(this)?.IsVisible == true && DataContext is MainViewModel model && model.ScanLocations.Count == 0 && model.RefreshScanLocationsCommand.CanExecute(null))
                await model.RefreshScanLocationsCommand.ExecuteAsync(null);
        };
    }
}
