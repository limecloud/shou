using Shou.Windows.Core;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Shou.Windows.Cli;

internal sealed record CommandSpec(string Command, string SideEffect, string[] Required, string[] Optional,
    string[] Repeated, string Description, bool Available = true, string? UnavailableReason = null);

internal static class CommandDiscovery
{
    private static readonly CommandSpec[] Commands =
    [
        new("capabilities", "read", [], ["command"], [], "Discover current commands, inputs and platform limits without opening storage."),
        new("rules schema", "read", [], [], [], "Read the bundled rule schema without network access."),
        new("rules catalog", "read", [], ["workspace"], [], "Read bundled templates or rules scoped to a registered workspace without importing them."),
        new("system locations", "read", [], ["include-projects"], [], "Inspect fixed and optional conventional project locations without registering or scanning them."),
        new("system scan", "snapshot", [], ["include-projects", "max-entries", "max-seconds", "max-depth"], [], "Prepare existing locations, then scan with bundled and explicitly enabled personal rules under one shared scan budget."),
        new("rules validate", "read", ["file"], [], [], "Validate a bounded local rule file without importing or enabling it."),
        new("analysis scan", "read", ["path"], ["max-entries", "max-seconds", "max-depth"], [], "Measure a local directory within a fixed budget without saving or changing targets."),
        new("privacy scan", "snapshot", [], ["range"], [], "Save aggregate counts from fixed current-user browser databases within a fixed time window; does not read browsing rows, delete records or repair databases."),
        new("privacy scan show", "read", ["scan-id"], [], [], "Read and validate saved privacy scan metadata without opening browser databases or granting execution."),
        new("applications summary", "read", [], ["search", "sort", "offset", "limit", "max-entries", "max-seconds"], [], "Discover bounded current-user and machine application registrations, with source coverage and unmeasured registered size estimates; does not open cleanup storage or uninstall applications."),
        new("startup list", "read", [], ["search", "source", "offset", "limit", "max-entries", "max-seconds"], [], "Read Run, RunOnce, Startup folders, visible boot/logon scheduled tasks and current-user packaged startup declarations without cleanup storage, arguments, shortcut resolution or startup changes. Includes Task Scheduler enablement and engine state when observed; effective startup and application activity remain unknown."),
        new("startup inspect", "read", ["task-path", "action"], [], [], "Review an exact boot/logon scheduled task, its current-user ownership, principal, ordinary interactive context and enablement without opening cleanup storage."),
        new("startup control", "destructive", ["task-path", "action", "review-digest"], [], [], "Recheck and confirm an exact reviewed task before changing only task Enabled; does not run, stop, register or delete tasks.", CliServices.StartupControlAvailable, "native_acceptance_pending"),
        new("startup execution show", "read", ["startup-operation-id"], [], [], "Read a startup operation intent and observed result without replay, rollback or task changes."),
        new("applications inspect", "read", ["application-id"], [], [], "Re-read MSI/MSIX identity, installation-directory activity, protection and installer data warnings without creating storage."),
        new("applications plan", "plan", ["application-id", "review-digest", "allow-installer-data-changes"], [], [], "Reinspect the exact reviewed installation and save a 15-minute plan after explicit installer-data acknowledgement; does not uninstall."),
        new("applications plan show", "read", ["uninstall-plan-id"], [], [], "Read and validate an uninstall plan; installation execution remains unavailable."),
        new("applications uninstall", "destructive", ["uninstall-plan-id"], [], [], "Invoke the exact system installer after current confirmation; no residual cleanup or Shou restore.", CliServices.ApplicationUninstallAvailable, "native_acceptance_pending"),
        new("applications execution show", "read", ["uninstall-plan-id"], [], [], "Read a plan-bound uninstall intent and its installer/identity outcomes without retrying or changing it."),
        new("workspaces list", "read", [], [], [], "List registered workspace roots without scanning them."),
        new("workspaces show", "read", ["workspace"], [], [], "Show a workspace and check its current root identity and access."),
        new("workspaces add", "configuration", ["path", "root-ref"], [], [], "Register a current-user-owned local directory; does not grant system permissions."),
        new("workspaces remove", "configuration", ["workspace"], [], [], "Unregister a workspace and its bindings; preserves targets, rules and saved observations."),
        new("workspaces exclude add", "configuration", ["workspace", "pattern"], ["project"], [], "Protect a workspace-relative pattern, optionally under an exact relative project directory."),
        new("workspaces exclude remove", "configuration", ["workspace", "pattern"], ["project"], [], "Remove an explicit workspace exclusion; does not change targets."),
        new("exclusions list", "read", [], ["workspace"], [], "Read global, optional workspace and effective exclusion patterns."),
        new("exclusions global add", "configuration", ["pattern"], [], [], "Protect a relative pattern in current and future workspaces; invalidates prior previews."),
        new("exclusions global remove", "configuration", ["pattern"], [], [], "Remove a global exclusion; preserves workspace and per-rule exclusions."),
        new("rules import", "configuration", ["file"], [], [], "Import an immutable rule version without enabling it."),
        new("rules list", "read", [], [], [], "List imported rule versions and local bindings."),
        new("rules show", "read", ["rule-id"], ["version"], [], "Read an imported rule definition; defaults to the most recently imported version."),
        new("rules export", "read", ["rule-id"], ["version"], [], "Return only the shareable rule definition in the result envelope."),
        new("rules enable", "configuration", ["rule-id", "workspace"], ["version"], [], "Enable a platform- and root-matched binding without authorizing cleanup."),
        new("rules disable", "configuration", ["rule-id", "workspace"], ["version"], [], "Disable an explicit rule binding without changing target files."),
        new("rules preview", "snapshot", ["file", "workspace"], ["max-entries", "max-seconds", "max-depth"], [], "Scan a draft and persist bounded review evidence without granting execution."),
        new("scan", "snapshot", ["workspace"], ["max-entries", "max-seconds", "max-depth"], [], "Scan the workspace with bundled and explicitly enabled personal rules and save current evidence; does not change targets."),
        new("scan results", "read", ["scan-id"], ["limit", "cursor"], [], "Page through immutable saved scan candidates; execution remains unavailable."),
        new("plan create", "plan", ["scan-id", "candidate"], ["mode"], ["candidate"], "Create a fixed plan from explicitly selected candidate IDs. Mode defaults to trash, which is currently unavailable; permanent requires explicit selection."),
        new("plan show", "read", ["plan-id"], [], [], "Read a saved immutable plan without granting confirmation or execution."),
        new("plan execute", "destructive", ["plan-id"], [], [], "Execute a current plan only after native acceptance and interactive current-scope confirmation.", CliServices.MutationAvailable, "native_acceptance_pending"),
        new("history list", "read", [], ["limit", "cursor"], [], "Page through bounded journal summaries; full plan verification requires history show."),
        new("history show", "read", ["execution-id"], [], [], "Read an execution journal and verify its binding to the saved plan."),
        new("history inspect", "read", ["execution-id"], ["max-entries", "max-seconds"], [], "Observe exact recorded original and Trash locations; never changes logs, retries operations or restores files.")
    ];

    public static bool IsGroup(string command) => Commands.Any(spec => spec.Command.StartsWith(command + " ", StringComparison.Ordinal)) &&
        !Commands.Any(spec => spec.Command == command && spec.Required.Length == 0);

    public static CommandRequest Parse(List<string> arguments)
    {
        var spec = Commands.OrderByDescending(value => value.Command.Length).FirstOrDefault(value =>
            arguments.Take(value.Command.Split(' ').Length).SequenceEqual(value.Command.Split(' ')))
            ?? throw new ShouException("invalid_argument", "Unknown command. Use shou --help.");
        var values = new Dictionary<string, string[]>(StringComparer.Ordinal);
        var allowed = spec.Required.Concat(spec.Optional).ToHashSet(StringComparer.Ordinal);
        for (var index = spec.Command.Split(' ').Length; index < arguments.Count; index += 2)
        {
            var option = arguments[index];
            if (!option.StartsWith("--", StringComparison.Ordinal) || !allowed.Contains(option[2..]) ||
                index + 1 >= arguments.Count || string.IsNullOrWhiteSpace(arguments[index + 1]) ||
                arguments[index + 1].StartsWith("--", StringComparison.Ordinal))
                throw new ShouException("invalid_argument", "Unknown, duplicate, empty or incomplete arguments.");
            var name = option[2..];
            if (values.TryGetValue(name, out var previous))
            {
                if (!spec.Repeated.Contains(name) || previous.Length >= 256) throw new ShouException("invalid_argument", "Only candidate selections may be repeated, at most 256 times.");
                values[name] = [.. previous, arguments[index + 1]];
            }
            else values.Add(name, [arguments[index + 1]]);
        }
        if (spec.Required.Any(name => !values.ContainsKey(name))) throw new ShouException("invalid_argument", "A required option is missing. Use command --help.");
        return new(spec.Command, values);
    }

    public static CommandSpec[] Matching(string command)
    {
        var selected = Commands.Where(spec => command.Length == 0 || spec.Command == command ||
            spec.Command.StartsWith(command + " ", StringComparison.Ordinal)).ToArray();
        return selected.Length > 0 ? selected : throw new ShouException("invalid_argument", "Unknown command or group. Use shou --help.");
    }

    public static string Help(string command)
    {
        var lines = new List<string> { "Shou · 收拾一下", "Usage: shou <command> [options] [--json] [--locale en|zh-CN]", "" };
        foreach (var spec in Matching(command))
        {
            var inputs = spec.Required.Select(name => $"--{name} <value>").Concat(spec.Optional.Select(name => $"[--{name} <value>]"));
            lines.Add($"  {spec.Command} {string.Join(' ', inputs)}");
            lines.Add($"      [{spec.SideEffect}] {spec.Description}");
            if (!spec.Available) lines.Add($"      Unavailable: {spec.UnavailableReason}");
        }
        lines.Add("");
        if (command.Length == 0 || command is "startup" or "startup list")
            lines.Add("Startup sources: current-user-run, current-user-run-once, machine-run64, machine-run32, machine-run-once64, machine-run-once32, current-user-startup, common-startup, scheduled-tasks, packaged-startup-tasks.");
        lines.Add("Use capabilities --command <command-or-group> --json for focused machine discovery.");
        return string.Join(Environment.NewLine, lines);
    }
}

internal sealed record CommandRequest(string Command, IReadOnlyDictionary<string, string[]> Values)
{
    public string Required(string name) => Values[name][0];
    public string? Optional(string name) => Values.GetValueOrDefault(name)?[0];
    public string[] All(string name) => Values.GetValueOrDefault(name) ?? [];
    public CleanupAction Action => Optional("mode") == "permanent" ? CleanupAction.Permanent : CleanupAction.Trash;
    public bool IncludeProjects => Optional("include-projects") == "true";
    public PrivacyTimeRange PrivacyRange => Optional("range") switch
    {
        null or "last-hour" => PrivacyTimeRange.LastHour, "last-day" => PrivacyTimeRange.LastDay,
        "last-seven-days" => PrivacyTimeRange.LastSevenDays, "all-time" => PrivacyTimeRange.AllTime,
        _ => throw Invalid("Choose last-hour, last-day, last-seven-days or all-time.")
    };
    public WindowsPath? Path => Optional("path") is { } path ? WindowsPath.Parse(path) : null;
    public int PageLimit => Integer("limit", 50);
    public ScanBudget Budget => new(Integer("max-entries", 100_000), Integer("max-depth", 32), TimeSpan.FromSeconds(Integer("max-seconds", 120)));
    public ApplicationDiscoveryBudget ApplicationBudget => new(Integer("max-entries", 4000), TimeSpan.FromSeconds(Integer("max-seconds", 10)));
    public StartupDiscoveryBudget StartupBudget => new(Integer("max-entries", 2000), TimeSpan.FromSeconds(Integer("max-seconds", 5)));
    public StartupControlAction StartupAction => Optional("action") switch
    {
        "enable" => StartupControlAction.Enable, "disable" => StartupControlAction.Disable,
        _ => throw Invalid("Choose enable or disable for the scheduled-task switch.")
    };
    public StartupQuery StartupQuery => new(Optional("search") ?? "", Optional("source") switch
    {
        null => null,
        "current-user-run" => StartupSource.CurrentUserRun,
        "current-user-run-once" => StartupSource.CurrentUserRunOnce,
        "machine-run64" => StartupSource.MachineRun64,
        "machine-run32" => StartupSource.MachineRun32,
        "machine-run-once64" => StartupSource.MachineRunOnce64,
        "machine-run-once32" => StartupSource.MachineRunOnce32,
        "current-user-startup" => StartupSource.CurrentUserStartup,
        "common-startup" => StartupSource.CommonStartup,
        "scheduled-tasks" => StartupSource.ScheduledTasks,
        "packaged-startup-tasks" => StartupSource.PackagedStartupTasks,
        _ => throw Invalid("Choose a supported startup source from startup list --help.")
    }, Integer("offset", 0), Integer("limit", 100));
    public ApplicationQuery ApplicationQuery => new(Optional("search") ?? "", Optional("sort") switch
    {
        null or "name" => ApplicationSort.Name,
        "registered-size" => ApplicationSort.RegisteredSize,
        _ => throw Invalid("Choose name or registered-size sorting.")
    }, Integer("offset", 0), Integer("limit", 100));

    public void Validate()
    {
        _ = Path;
        if (Command == "privacy scan") _ = PrivacyRange;
        if (Command == "applications summary") { ApplicationBudget.Validate(); ApplicationQuery.Validate(); }
        if (Command == "startup list") { StartupBudget.Validate(); StartupQuery.Validate(); }
        if (Command is "startup inspect" or "startup control")
        {
            _ = StartupAction;
            if (!StartupControlReviewer.ValidTaskPath(Required("task-path"))) throw Invalid("Choose an exact scheduled-task identifier.");
        }
        if (Optional("startup-operation-id") is { } startupOperation && !RecordKey.IsId(startupOperation, "startup_control")) throw Invalid("Choose a valid startup operation identifier.");
        if (Optional("application-id") is { } applicationId && !ApplicationCatalog.IsApplicationId(applicationId)) throw Invalid("Choose a valid application identifier.");
        if (Optional("review-digest") is { } reviewDigest && (reviewDigest.Length != 71 || !reviewDigest.StartsWith("sha256:", StringComparison.Ordinal) || !reviewDigest[7..].All(character => char.IsAsciiDigit(character) || character is >= 'a' and <= 'f')))
            throw Invalid("Choose the exact SHA-256 digest returned by the relevant inspection.");
        if (Optional("allow-installer-data-changes") is { } installerData && installerData is not ("true" or "false")) throw Invalid("Choose true or false for installer-managed data changes.");
        if (Optional("uninstall-plan-id") is { } uninstallPlan && !RecordKey.IsId(uninstallPlan, "uninstall_plan")) throw Invalid("Choose a valid uninstall plan identifier.");
        if (Command is "analysis scan" or "rules preview" or "scan" or "system scan") Budget.Validate();
        if (Command == "history inspect") Budget.Validate();
        if (Optional("root-ref") is { } rootRef && !ConfigurationCodec.ValidRootRef(rootRef)) throw Invalid("Choose a valid logical root reference.");
        if (Optional("include-projects") is { } projects && projects is not ("true" or "false")) throw Invalid("Choose true or false for include-projects.");
        if (Optional("workspace") is { } workspace && !RecordKey.IsId(workspace, "ws")) throw Invalid("Choose a valid workspace identifier.");
        if (Optional("scan-id") is { } scan && !RecordKey.IsId(scan, Command.StartsWith("privacy ", StringComparison.Ordinal) ? "privacy_scan" : "scan")) throw Invalid("Choose a valid scan identifier.");
        if (Optional("plan-id") is { } plan && !RecordKey.IsId(plan, "plan")) throw Invalid("Choose a valid plan identifier.");
        if (Optional("execution-id") is { } execution && !RecordKey.IsId(execution, "execution")) throw Invalid("Choose a valid execution identifier.");
        if (Optional("mode") is { } mode && mode is not ("trash" or "permanent")) throw Invalid("Choose trash or permanent mode.");
        if (Command == "plan create" && (All("candidate").Any(id => !RecordKey.IsId(id, "candidate")) ||
            All("candidate").Distinct(StringComparer.Ordinal).Count() != All("candidate").Length)) throw Invalid("Choose distinct candidate identifiers from this scan.");
        if (Optional("pattern") is { } pattern) _ = new RulePattern(pattern);
        if (Optional("project") is { } project)
        {
            WindowsPath.ValidateRelative(project);
            _ = new RulePattern(project + "/" + Required("pattern"));
        }
        if (Optional("rule-id") is { } id && (id.Length > 128 || !Regex.IsMatch(id, "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)))
            throw Invalid("Choose a valid rule identifier.");
        if (Optional("version") is { } version && (version.Length > 32 || !Regex.IsMatch(version, "^[0-9]+\\.[0-9]+\\.[0-9]+$", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)))
            throw Invalid("Choose a valid rule version.");
        if (Command is "scan results" or "history list" && (PageLimit is < 1 or > 500 || Optional("cursor") is { Length: > 512 })) throw Invalid("Choose a page limit from 1 to 500 and a bounded cursor.");
    }

    private int Integer(string name, int fallback) => Optional(name) is not { } value ? fallback :
        int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var result) ? result : throw Invalid("Numeric options must be positive integers.");
    private static ShouException Invalid(string message) => new("invalid_argument", message);
}
