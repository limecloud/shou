using System.Reflection;
using System.Text.Json;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.Cli;

internal static class Program
{
    private static readonly string Version = typeof(Program).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "development";
    private static bool HostSupported => NativeWindowsSupport.IsSupported;

    private static async Task<int> Main(string[] args)
    {
        if (IsSupportRequest(args)) return await ExecuteAsync(args, "request_" + Guid.NewGuid().ToString("N"));
        if (HostSupported) NativeDiagnostics.Initialize();
        using var diagnostic = OperationDiagnostics.Start("cli.request");
        try
        {
            var exit = await ExecuteAsync(args, "request_" + diagnostic.Id);
            diagnostic.Complete(exit switch { 0 => "success", 6 => "partial", 130 => "cancelled", _ => "error" }, count: exit);
            return exit;
        }
        catch (Exception error) { diagnostic.Fail(error); throw; }
    }

    private static async Task<int> ExecuteAsync(string[] args, string requestId)
    {
        using var cancelled = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancelled.Cancel(); };
        try
        {
            var arguments = new List<string>(args);
            var json = RemoveFlag(arguments, "--json");
            var locale = RemoveOption(arguments, "--locale") ?? "en";
            if (locale is not ("en" or "en-US" or "zh-CN" or "zh-Hans")) throw Input("Unsupported locale.");
            var help = RemoveFlag(arguments, "--help");
            if (arguments.Count == 0 || help || CommandDiscovery.IsGroup(string.Join(' ', arguments)))
            {
                var command = string.Join(' ', arguments);
                if (json) return Write(requestId, new { command = "shou", version = Version, commands = CommandDiscovery.Matching(command) });
                Console.WriteLine(CommandDiscovery.Help(command));
                return 0;
            }
            if (arguments.SequenceEqual(["--version"]))
            {
                if (json) return Write(requestId, new { version = Version });
                Console.WriteLine(Version);
                return 0;
            }
            var request = CommandDiscovery.Parse(arguments);
            request.Validate();
            using (var commandDiagnostic = OperationDiagnostics.Start("cli.command"))
            { commandDiagnostic.Step(request.Command.Replace(' ', '.')); commandDiagnostic.Complete("validated"); }
            if (request.Command == "capabilities")
                return Write(requestId, new
                {
                    application_version = Version, api_version = "1.0", rule_schema_version = "1.0",
                    platform = "windows", architectures = new[] { "x64", "arm64" }, runtime_locales = new[] { "en", "zh-CN" },
                    host_supported = HostSupported, commands = CommandDiscovery.Matching(request.Optional("command") ?? ""),
                    trash_available = false, mutation_available = CliServices.MutationAvailable, application_uninstall_available = CliServices.ApplicationUninstallAvailable, confirmation = "interactive_current_scope",
                    startup_control_available = CliServices.StartupControlAvailable,
                    limits = new { rule_bytes = RuleSchemaValidator.MaximumRuleBytes, scan_entries = 100_000, scan_entries_max = 1_000_000,
                        scan_seconds = 120, scan_seconds_max = 3600, scan_depth_max = 64, page_size = 500,
                        snapshot_bytes = CleanupScanService.MaximumSnapshotBytes, history_directory_entries = CleanupHistoryService.MaximumDirectoryEntries,
                        application_entries = 4000, application_entries_max = 20_000, application_seconds = 10, application_seconds_max = 60,
                        startup_entries = 2000, startup_entries_max = 10_000, startup_seconds = 5, startup_seconds_max = 60,
                        startup_task_xml_characters = 262_144, startup_task_folder_depth = 32,
                        startup_manifest_bytes = 4_194_304,
                        privacy_sources = PrivacySourceDiscovery.MaximumSources, privacy_profiles = PrivacySourceDiscovery.MaximumProfiles,
                        privacy_discovery_entries = PrivacySourceDiscovery.MaximumEntries, privacy_scan_bytes = PrivacyScanService.MaximumScanBytes,
                        privacy_scan_seconds = 120, privacy_query_seconds = 15,
                        application_activity_entries = ApplicationActivityService.MaximumEntries, application_activity_seconds = ApplicationActivityService.Duration.TotalSeconds,
                        application_activity_depth = ApplicationActivityService.MaximumDepth, application_executable_names = ApplicationActivityService.MaximumExecutableNames,
                        history_list_bytes = CleanupHistoryService.MaximumListBytes, history_list_seconds = CleanupHistoryService.ListDuration.TotalSeconds },
                    limitations = new[] { "Local NTFS/ReFS only", "Trash and restore are unavailable", "Rule previews do not grant execution" }
                });
            if (request.Command == "rules schema") return Write(requestId, RuleResources.CreateValidator().ExportSchema());
            if (request.Command == "completion")
            {
                var shell = request.Required("shell");
                var script = CommandCompletion.Script(shell);
                if (json) return Write(requestId, new { shell, script });
                Console.Write(script);
                return 0;
            }
            if (request.Command == "rules catalog" && request.Optional("workspace") is null)
            {
                var home = WindowsPath.Parse("C:/ShouCatalogValidation");
                var catalog = RuleResources.CreateCatalog(RuleResources.CreateValidator(), new(home, home.Append("AppData/Local"), home.Append("AppData/Roaming")));
                return Write(requestId, catalog.Templates);
            }
            RequireWindows();
            if (request.Command is "applications updates source" or "applications updates check")
            {
                var checker = WindowsApplicationUpdateCatalog.CreateChecker();
                var result = request.Command == "applications updates source"
                    ? await checker.SourceAsync(request.Required("application-id"), null, cancelled.Token)
                    : await checker.CheckAsync(request.Required("application-id"), null, cancelled.Token);
                return Write(requestId, result, result.Status == "partial" ? "partial" : "success", result.Status == "partial" ? 6 : 0);
            }
            if (request.Command == "diagnostics")
            {
                var report = await new WindowsUserDiagnostics(Version).CollectAsync(cancelled.Token);
                if (json) return Write(requestId, report, report.Status == "partial" ? "partial" : "success", report.Status == "partial" ? 6 : 0);
                Console.Write(report.Text(new TextCatalog(locale).Get));
                return report.Status == "partial" ? 6 : 0;
            }
            if (request.Command == "startup list")
            {
                var snapshot = await new StartupInventoryService(new WindowsStartupInventory()).ReadAsync(request.StartupBudget, cancelled.Token);
                var page = StartupInventoryService.Page(snapshot, request.StartupQuery);
                return Write(requestId, page, page.State == ScanState.Complete ? "success" : "partial", page.State == ScanState.Complete ? 0 : 6);
            }
            if (request.Command == "startup inspect")
                return Write(requestId, await CliServices.StartupReviewer.InspectAsync(request.Required("task-path"), request.StartupAction, cancelled.Token));
            if (request.Command == "applications summary")
            {
                var snapshot = await new ApplicationCatalog(new WindowsApplicationInventory()).ReadAsync(request.ApplicationBudget, cancelled.Token);
                var page = ApplicationCatalog.Page(snapshot, request.ApplicationQuery);
                return Write(requestId, page, page.State == ScanState.Complete ? "success" : "partial", page.State == ScanState.Complete ? 0 : 6);
            }
            if (request.Command == "applications inspect")
                return Write(requestId, await CliServices.ApplicationReviewer.InspectAsync(request.Required("application-id"), cancelled.Token));
            if (request.Command == "rules validate")
            {
                var rule = RuleResources.CreateValidator().Parse(await CliServices.ReadRuleAsync(request.Required("file"), cancelled.Token));
                return Write(requestId, new { valid = true, rule_id = rule.Id, version = rule.Version, digest = rule.Digest, runtime_verified = false });
            }
            if (request.Command == "analysis scan")
            {
                var history = new StorageComparisonService(WindowsRecordStore.ForCurrentUser());
                var result = await new HistoricalStorageScanner(new StorageScanner(new WindowsFileSystem()), history).ScanAsync(request.Path!, request.Budget, null, cancelled.Token);
                return Write(requestId, result, result.State switch { ScanState.Complete => "success", ScanState.Cancelled => "cancelled", _ => "partial" },
                    result.State switch { ScanState.Complete => 0, ScanState.Cancelled => 130, _ => 6 });
            }
            if (request.Command == "analysis history")
            {
                var history = await new StorageComparisonService(WindowsRecordStore.ForCurrentUser()).HistoryAsync(request.Required("scan-id"), cancelled.Token);
                return Write(requestId, history, history.Status == "partial" ? "partial" : "success", history.Status == "partial" ? 6 : 0);
            }
            if (request.Command == "analysis compare")
            {
                var comparison = await new StorageComparisonService(WindowsRecordStore.ForCurrentUser()).CompareAsync(request.Required("baseline-id"), request.Required("scan-id"),
                    request.Optional("path") ?? ".", request.PageLimit, int.Parse(request.Optional("max-entries") ?? "100000", System.Globalization.CultureInfo.InvariantCulture),
                    int.Parse(request.Optional("max-seconds") ?? "10", System.Globalization.CultureInfo.InvariantCulture), cancelled.Token);
                return Write(requestId, comparison, comparison.Status == "partial" ? "partial" : "success", comparison.Status == "partial" ? 6 : 0);
            }
            var response = await LocalCommands.ExecuteAsync(request, new CliServices(), locale, cancelled.Token);
            return Write(requestId, response.Data, response.Status, response.ExitCode, nextActions: response.NextActions);
        }
        catch (OperationCanceledException) when (cancelled.IsCancellationRequested)
        {
            return Write(requestId, null, "cancelled", 130, new { code = "cancelled", message = "The operation was cancelled.", details = new { }, retryable = true });
        }
        catch (Exception error) when (error is ShouException or UnauthorizedAccessException or IOException)
        {
            if (HostSupported && !IsSupportRequest(args)) NativeDiagnostics.Write(error);
            var code = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "io_error";
            var message = error is ShouException ? error.Message : "The local operation could not be completed.";
            var exit = code switch
            {
                "invalid_argument" or "invalid_path" or "invalid_rule" or "unsupported_schema" => 2,
                "permission_denied" => 3,
                "source_changed" or "active_or_inaccessible" or "version_conflict" or "store_busy" or "plan_stale" or "plan_consumed" or "active_target" or "activity_unknown" or "preview_only" or "application_changed" or "startup_changed" => 4,
                "tracked_artifact_content" or "artifact_evidence_unavailable" => 4,
                "time_limit" or "resource_limit" or "application_discovery_incomplete" => 6,
                "confirmation_required" or "installer_data_consent_required" => 7,
                "unsupported_platform" or "unsupported_filesystem" or "unsupported_location" or "unsupported_capability" or "comparison_unavailable" => 8,
                _ => 5
            };
            return Write(requestId, null, "error", exit, new { code, message, details = new { }, retryable = code == "store_busy" });
        }
    }

    private static int Write(string requestId, object? data, string status = "success", int exit = 0, object? error = null, object[]? nextActions = null)
    {
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            api_version = "1.0", request_id = requestId, ok = status == "success", status, data,
            warnings = Array.Empty<object>(), error, next_actions = nextActions ?? []
        }, ContractJson.Options));
        return exit;
    }

    private static bool RemoveFlag(List<string> arguments, string flag)
    {
        var count = arguments.Count(value => value == flag);
        if (count > 1) throw Input("Duplicate arguments are not supported.");
        return arguments.Remove(flag);
    }

    private static bool IsSupportRequest(string[] args)
    {
        var arguments = new List<string>(args);
        try
        {
            RemoveFlag(arguments, "--json"); RemoveFlag(arguments, "--help"); RemoveOption(arguments, "--locale");
            return arguments.FirstOrDefault() is "diagnostics" or "completion" || arguments.Take(2).SequenceEqual(["applications", "updates"]);
        }
        catch (ShouException) { return false; }
    }

    private static string? RemoveOption(List<string> arguments, string name)
    {
        var index = arguments.IndexOf(name);
        if (index < 0) return null;
        if (arguments.Count(value => value == name) != 1 || index + 1 >= arguments.Count || arguments[index + 1].StartsWith("--", StringComparison.Ordinal))
            throw Input("An option is missing a value or was repeated.");
        var value = arguments[index + 1];
        arguments.RemoveRange(index, 2);
        return value;
    }

    private static ShouException Input(string message) => new("invalid_argument", message);

    private static void RequireWindows()
    {
        if (!HostSupported) throw new ShouException("unsupported_platform", "This native CLI requires 64-bit Windows 11.");
    }
}
