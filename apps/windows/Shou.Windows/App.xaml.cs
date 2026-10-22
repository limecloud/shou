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
            var preferenceStore = new DesktopPreferenceStore(DesktopPreferenceStore.DefaultPath);
            var preferences = new DesktopPreferences(); string? preferenceIssue = null;
            if (!verifyPackage)
            {
                try { preferences = preferenceStore.Read(); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or FormatException or System.Text.Json.JsonException)
                { preferenceIssue = "invalid_preferences"; }
            }
            else
            {
                var language = Environment.GetEnvironmentVariable("SHOU_PACKAGE_VERIFICATION_LANGUAGE") ?? "zh-CN";
                if (language is not ("zh-CN" or "en")) throw new InvalidOperationException("Invalid package verification language.");
                preferences = new DesktopPreferences(Language: language);
            }
            UiText.SetLanguage(preferences.Language, System.Globalization.CultureInfo.InstalledUICulture);
            DesktopPresentation.Current.Apply(preferences);
            var engine = Path.Combine(AppContext.BaseDirectory, "Engine", "shou.exe");
            if (e.Args.Length == 2 && e.Args[0] == "--engine") engine = e.Args[1];
            else if (e.Args.Length != 0 && !verifyPackage) throw new BridgeException("invalid_argument", T("源码运行参数为 --engine <shou.exe 的绝对路径>。"));
            var window = new MainWindow();
            var client = new BridgeProcessClient(engine);
            window.DataContext = new MainViewModel(client, new WindowsDialogs(window), preferenceStore, preferences, preferenceIssue, persistUserPreferences: !verifyPackage);
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
                model.VerifyRegisteredUninstallLayout();model.SelectedSection=7;
                window.Measure(new Size(1280,800));window.Arrange(new Rect(0,0,1280,800));window.UpdateLayout();
                model.VerifyPackageDataLayout();
                model.VerifyApplicationUsageLayout();
                foreach (var size in new[] { new Size(1280,800), new Size(840,580) }) {
                    window.Measure(size);window.Arrange(new Rect(new Point(0,0),size));window.UpdateLayout();
                }
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
                foreach (var json in new[] {
                    """{"records":[{"byte_count":4096}],"total_bytes":8192,"removable_bytes":4096,"retained_count":2,"issues":[]}""",
                    """{"records":[],"total_bytes":8192,"removable_bytes":0,"retained_count":2,"issues":[]}""",
                    """{"records":[],"total_bytes":8192,"removable_bytes":0,"retained_count":2,"issues":["unreadable_plan:layout-fixture"]}"""
                }) new RecordMaintenanceDialog(null, RecordMaintenanceSummary.Read(System.Text.Json.Nodes.JsonNode.Parse(json)!)).VerifyLayout();
                new FilePreviewDialog(null,client,"layout-fixture","preview.txt").VerifyLayout();
                new DiskCapacityView().VerifyLayout();
                model.VerifyPrivacyLayout(); model.SelectedSection=9;
                foreach (var size in new[] { new Size(1280,800), new Size(840,580) }) {
                    window.Measure(size);window.Arrange(new Rect(new Point(0,0),size));window.UpdateLayout();
                }
                var workspace=new WorkspaceRow("layout-fixture","C:/layout-fixture","layout-fixture");
                model.VerifyToolsLayout();model.SelectedSection=10;
                foreach (var size in new[] { new Size(1280,800),new Size(840,580) }) {
                    window.Measure(size);window.Arrange(new Rect(new Point(0,0),size));window.UpdateLayout();
                }
                new ApplicationDataDialog(null,client).VerifyLayout();
                new RuleAuthoringDialog(null,client,workspace,CancellationToken.None).VerifyLayout();
                var definition=new System.Text.Json.Nodes.JsonObject { ["id"]="personal.layout-fixture",["version"]="0.1.0",["scope"]=new System.Text.Json.Nodes.JsonObject { ["root_ref"]="layout-fixture" } };
                new RuleAuthoringDialog(null,client,workspace,CancellationToken.None,definition).VerifyLayout();
                var agentSetup=await client.RequestAsync("agent.setup");
                new AgentRuleSetupDialog(null,client,agentSetup,"C:/layout-fixture/中文 projects",CancellationToken.None).VerifyLayout();
                model.VerifySettingsLayout();
                foreach (var appearance in new[] { "system", "light", "dark" })
                foreach (var reduceMotion in new[] { false, true })
                {
                    DesktopPresentation.Current.Apply(preferences with { Appearance = appearance, ReduceMotion = reduceMotion });
                    if (reduceMotion && DesktopPresentation.Current.AnimateIndicators) throw new InvalidOperationException("Reduced motion was not applied.");
                    foreach (var size in new[] { new Size(1280,800), new Size(840,580) }) {
                        window.Measure(size);window.Arrange(new Rect(new Point(0,0),size));window.UpdateLayout();
                    }
                }
                DesktopPresentation.Current.Apply(preferences);
                var report = Environment.GetEnvironmentVariable("SHOU_PACKAGE_VERIFICATION_REPORT") ?? throw new InvalidOperationException("Missing package verification report path.");
                var cliDirectory=Path.Combine(Path.GetDirectoryName(Path.GetFullPath(report))!,"cli-fixture-"+UiText.Language);
                var cliInstallation=new WindowsCliInstallation(WindowsCliInstallation.BundledTemplate,client.ExecutablePath,cliDirectory);
                var cliReview=cliInstallation.Preview();
                cliInstallation.Install(cliReview.Digest);
                if(!cliInstallation.Preview().AlreadyCurrent)throw new InvalidOperationException("Packaged user CLI installation was not verified.");
                File.WriteAllText(report, System.Text.Json.JsonSerializer.Serialize(new { assembly_version = typeof(App).Assembly.GetName().Version?.ToString(), application_version = capabilities["application_version"]?.GetValue<string>(), language = UiText.Language, wpf_layout_loaded = true, rule_authoring_layout_loaded = true, rule_settings_layout_loaded = true, application_inventory_layout_loaded = true, application_uninstall_layout_loaded = true, application_data_layout_loaded = true, application_usage_layout_loaded = true, package_data_layout_loaded = true, history_selection_layout_loaded = true, history_inspection_layout_loaded = true, record_maintenance_layout_loaded = true, scan_locations_layout_loaded = true, storage_browsing_layout_loaded = true, file_preview_layout_loaded = true, system_preview_surface_loaded = true, disk_capacity_layout_loaded = true, privacy_layout_loaded = true, cleanup_closing_state_verified = true, tools_layout_loaded = true, settings_layout_loaded = true, agent_setup_layout_loaded = true, cli_installation_verified = true, presentation_preferences_verified = true }));
                Shutdown(0); return;
            }
            MainWindow = window; window.Show();
        }
        catch (Exception error) { if (verifyPackage) Console.Error.WriteLine(error); else MessageBox.Show(error.Message, T("Shou · 启动未完成"), MessageBoxButton.OK, MessageBoxImage.Error); Shutdown(1); }
    }
}
