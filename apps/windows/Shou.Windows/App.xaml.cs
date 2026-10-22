using System.IO;
using System.Windows;
using Shou.Windows.Services;

namespace Shou.Windows;

public partial class App : Application
{
    public App()
    {
        if (Environment.GetEnvironmentVariable("SHOU_PACKAGE_VERIFICATION_REPORT") is { } report)
            AppDomain.CurrentDomain.UnhandledException += (_, value) => File.WriteAllText(report, value.ExceptionObject.ToString());
    }

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var verifyPackage = e.Args.Length == 1 && e.Args[0] == "--verify-package";
        try
        {
            var engine = Path.Combine(AppContext.BaseDirectory, "Engine", "shou.exe");
            if (e.Args.Length == 2 && e.Args[0] == "--engine") engine = e.Args[1];
            else if (e.Args.Length != 0 && !verifyPackage) throw new BridgeException("invalid_argument", "源码运行参数为 --engine <shou.exe 的绝对路径>。");
            var window = new MainWindow();
            var client = new BridgeProcessClient(engine);
            window.DataContext = new MainViewModel(client, new WindowsDialogs(window));
            if (verifyPackage)
            {
                // Exercise the shipped WPF resources and bundled engine without
                // scanning user folders or opening an unattended CI window.
                var capabilities = await client.RequestAsync("capabilities");
                if (capabilities["platform"]?.GetValue<string>() != "windows") throw new BridgeException("incompatible_engine", "Windows package requires a Windows engine.");
                window.Measure(new Size(1280, 800));
                window.Arrange(new Rect(0, 0, 1280, 800));
                window.UpdateLayout();
                var model=(MainViewModel)window.DataContext;
                model.VerifyCleanupClosingState();
                model.Candidates.Add(new("layout-candidate", "项目 中文/build/cache", 8192, true, "生成布局夹具", "layout-scan", "layout-workspace", "C:/layout-fixture", false, "build", "layout-rule", true, 2));
                model.SelectedCleanupCandidate = model.Candidates[0];
                foreach (var size in new[] { new Size(1280,800), new Size(840,580) }) {
                    window.Measure(size);window.Arrange(new Rect(new Point(0,0),size));window.UpdateLayout();
                }
                model.SelectedSection=2;
                foreach(var scope in new[] { 0,1,2 }) {
                    model.ExclusionScope=scope;
                    window.Measure(new Size(1280,800));window.Arrange(new Rect(0,0,1280,800));window.UpdateLayout();
                }
                model.SelectedSection=7;
                window.Measure(new Size(1280,800));window.Arrange(new Rect(0,0,1280,800));window.UpdateLayout();
                model.ScanLocations.Add(new("layout-included", "额外项目", "C:/layout-fixture/中文 projects", "included", "available", null, "layout-included", true));
                model.ScanLocations.Add(new("layout-automatic", "自动项目", "C:/Users/layout/Projects", "automatic", "available", null, null, false));
                model.ScanLocations.Add(new("layout-cache", "内置缓存", "C:/Users/layout/AppData/Local/fixture/Cache", "builtin", "unavailable", "夹具：无法读取位置", null, false));
                model.SelectedSection=8;
                foreach (var location in model.ScanLocations) {
                    model.SelectedScanLocation=location;
                    window.Measure(new Size(840,580));window.Arrange(new Rect(0,0,840,580));window.UpdateLayout();
                }
                model.History.Add(new("layout-fixture", "2026-10-22", "C:/layout-fixture", "partial", [
                    new("selected", "C:/layout-fixture/build/cache", "trashed", 4096, true, true, null, "C:/$Recycle.Bin/layout-fixture"),
                    new("pending", "C:/layout-fixture/target", "needs_verification", 8192, false, false, "需要核实", null)
                ]));
                model.SelectedHistory=model.History[0];model.SelectedSection=3;
                model.SelectHistoryItemsCommand.Execute(null);
                if (!model.HistoryItems[0].IsSelected || model.HistoryItems[1].IsSelected) throw new InvalidOperationException("History selection included a blocked item.");
                foreach (var size in new[] { new Size(1280,800), new Size(840,580) }) {
                    window.Measure(size);window.Arrange(new Rect(new Point(0,0),size));window.UpdateLayout();
                }
                model.SelectedHistory=null;
                if (model.HistoryItems.Count!=0 || model.ClearHistoryItemsCommand.CanExecute(null)) throw new InvalidOperationException("History selection survived a record change.");
                model.SelectedSection=1;
                foreach (var detailed in new[] { false, true }) {
                    model.VerifyStorageLayout(detailed);
                    foreach (var size in new[] { new Size(1280,800), new Size(840,580) }) {
                        window.Measure(size);window.Arrange(new Rect(new Point(0,0),size));window.UpdateLayout();
                    }
                }
                new HistoryInspectionDialog(null,client,"layout-fixture").VerifyLayout();
                new FilePreviewDialog(null,client,"layout-fixture","preview.txt").VerifyLayout();
                new DiskCapacityView().VerifyLayout();
                model.VerifyPrivacyLayout(); model.SelectedSection=9;
                foreach (var size in new[] { new Size(1280,800), new Size(840,580) }) {
                    window.Measure(size);window.Arrange(new Rect(new Point(0,0),size));window.UpdateLayout();
                }
                var workspace=new WorkspaceRow("layout-fixture","C:/layout-fixture","layout-fixture");
                new RuleAuthoringDialog(null,client,workspace,CancellationToken.None).VerifyLayout();
                var definition=new System.Text.Json.Nodes.JsonObject { ["id"]="personal.layout-fixture",["version"]="0.1.0",["scope"]=new System.Text.Json.Nodes.JsonObject { ["root_ref"]="layout-fixture" } };
                new RuleAuthoringDialog(null,client,workspace,CancellationToken.None,definition).VerifyLayout();
                var report = Environment.GetEnvironmentVariable("SHOU_PACKAGE_VERIFICATION_REPORT") ?? throw new InvalidOperationException("Missing package verification report path.");
                File.WriteAllText(report, System.Text.Json.JsonSerializer.Serialize(new { assembly_version = typeof(App).Assembly.GetName().Version?.ToString(), application_version = capabilities["application_version"]?.GetValue<string>(), wpf_layout_loaded = true, rule_authoring_layout_loaded = true, rule_settings_layout_loaded = true, application_inventory_layout_loaded = true, history_selection_layout_loaded = true, history_inspection_layout_loaded = true, scan_locations_layout_loaded = true, storage_browsing_layout_loaded = true, file_preview_layout_loaded = true, disk_capacity_layout_loaded = true, privacy_layout_loaded = true, cleanup_closing_state_verified = true }));
                Shutdown(0); return;
            }
            MainWindow = window; window.Show();
        }
        catch (Exception error) { if (verifyPackage) Console.Error.WriteLine(error); else MessageBox.Show(error.Message, "Shou · 启动未完成", MessageBoxButton.OK, MessageBoxImage.Error); Shutdown(1); }
    }
}
