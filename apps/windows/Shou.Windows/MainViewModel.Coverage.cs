using CommunityToolkit.Mvvm.Input;
using System.Text.Json.Nodes;

namespace Shou.Windows;

public sealed partial class MainViewModel
{
    private StorageCoverageSummary? largeFilesCoverage;
    public IAsyncRelayCommand StorageCoverageCommand { get;private set; }=null!;
    public IAsyncRelayCommand LargeFilesCoverageCommand { get;private set; }=null!;
    private void InitializeStorageCoverage()
    {
        StorageCoverageCommand=new AsyncRelayCommand(()=>ReviewCoverageAsync(storageCoverage!,false),()=>!IsBusy && !AiBusy && storageCoverage is not null);
        LargeFilesCoverageCommand=new AsyncRelayCommand(()=>ReviewCoverageAsync(largeFilesCoverage!,true),()=>!IsBusy && !AiBusy && largeFilesCoverage is not null);
        commands.AddRange([StorageCoverageCommand,LargeFilesCoverageCommand]);
    }
    private async Task ReviewCoverageAsync(StorageCoverageSummary summary,bool largeFiles)
    {
        if(!dialogs.ReviewStorageCoverage(summary))return;
        await RunAsync(()=>largeFiles ? ScanLargeFilesAtPathAsync(summary.RootPath) : ScanStorageAsync(summary.RootPath));
    }
    internal void VerifyStorageCoverageLayout()
    {
        largeFilesCoverage=StorageCoverageSummary.Read(JsonNode.Parse("""
            {"scan_id":"layout_coverage","root_path":"C:/layout-fixture/中文 projects","status":"partial","entry_count":1200,
            "coverage_notes":[{"code":"unreadable_directory","path":"project/cache","system_managed":false},
            {"code":"unreadable","path":"Windows","system_managed":true},{"code":"resource_limit","path":".","system_managed":false}]}
            """)!);
        if(!LargeFilesCoverageCommand.CanExecute(null))throw new InvalidOperationException("Saved large-file coverage is unavailable.");
        new StorageCoverageDialog(null,largeFilesCoverage).VerifyLayout();
        new StorageCoverageDialog(null,largeFilesCoverage with { Status="complete",Items=[] }).VerifyLayout();
        new StorageCoverageDialog(null,largeFilesCoverage with { Items=[] }).VerifyLayout();
    }
}
