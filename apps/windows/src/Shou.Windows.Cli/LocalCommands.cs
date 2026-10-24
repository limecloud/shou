using Shou.Windows.Core;

namespace Shou.Windows.Cli;

internal sealed record CommandResult(object Data, string Status = "success", int ExitCode = 0, object[]? NextActions = null);

internal static class LocalCommands
{
    public static async Task<CommandResult> ExecuteAsync(CommandRequest request, CliServices services, string locale, CancellationToken cancellationToken)
    {
        var configuration = services.Configuration;
        switch (request.Command)
        {
            case "privacy scan":
            {
                var scan = await services.Privacy.ScanAsync(request.PrivacyRange, cancellationToken);
                return new(scan, scan.Complete ? "success" : "partial", scan.Complete ? 0 : 6,
                    [new { command = "privacy scan show", arguments = new { scan_id = scan.Id } }]);
            }
            case "privacy scan show": return new(await services.Privacy.ReadAsync(request.Required("scan-id"), cancellationToken));
            case "startup execution show": return new(await services.StartupControl.ShowAsync(request.Required("startup-operation-id"), cancellationToken));
            case "startup control":
            {
                if (!CliServices.StartupControlAvailable) throw new ShouException("unsupported_capability", "Startup changes require a matching native Windows 11 process. No task setter was invoked.");
                var review = await CliServices.StartupReviewer.InspectAsync(request.Required("task-path"), request.StartupAction, cancellationToken);
                if (review.Digest != request.Required("review-digest")) throw new ShouException("startup_changed", "The task changed after review. Inspect it again before confirming.");
                var next = new object[] { new { command = "startup execution show", arguments = new { startup_operation_id = review.Id } } };
                try
                {
                    var result = await services.StartupControl.ExecuteAsync(review, new TerminalStartupControlConfirmation(WindowsConsolePrompt.ReadAsync, locale), cancellationToken);
                    return new(result, result.State == StartupControlState.Completed ? "success" : result.State == StartupControlState.Cancelled ? "cancelled" : "partial",
                        result.State == StartupControlState.Completed ? 0 : result.State == StartupControlState.Cancelled ? 130 : 6, next);
                }
                catch (ShouException error) when (error.Code == "journal_write_failed")
                { return new(new { operation_id = review.Id, reason = error.Code, current_state_requires_observation = true }, "partial", 6, next); }
            }
            case "applications plan":
            {
                var plan = await services.ApplicationPlans.CreateAsync(request.Required("application-id"), request.Required("review-digest"),
                    request.Required("allow-installer-data-changes") == "true", cancellationToken);
                return new(plan, NextActions: [new { command = "applications plan show", arguments = new { uninstall_plan_id = plan.Id } }]);
            }
            case "applications plan show": return new(await services.ApplicationPlans.ShowAsync(request.Required("uninstall-plan-id"), cancellationToken));
            case "applications execution show": return new(await services.ApplicationUninstall.ShowAsync(request.Required("uninstall-plan-id"), cancellationToken));
            case "applications uninstall":
            {
                if (!CliServices.ApplicationUninstallAvailable) throw new ShouException("unsupported_capability", "System uninstall requires a matching native Windows 11 process. No installer was invoked.");
                var uninstall = services.ApplicationUninstall;
                var consent = await uninstall.ConfirmAsync(request.Required("uninstall-plan-id"), new TerminalApplicationUninstallConfirmation(WindowsConsolePrompt.ReadAsync, locale), cancellationToken);
                var execution = await uninstall.ExecuteAsync(request.Required("uninstall-plan-id"), consent, cancellationToken);
                return new(execution, execution.State == ApplicationUninstallState.Completed ? "success" : execution.State == ApplicationUninstallState.Cancelled ? "cancelled" : "partial",
                    execution.State == ApplicationUninstallState.Completed ? 0 : execution.State == ApplicationUninstallState.Cancelled ? 130 : 6,
                    [new { command = "applications execution show", arguments = new { uninstall_plan_id = execution.PlanId } }]);
            }
            case "rules catalog": return new((await configuration.BuiltinRulesAsync(request.Required("workspace"), cancellationToken)).Select(rule => rule.Definition).ToArray());
            case "system locations": return new(await services.Locations.DiscoverAsync(request.IncludeProjects, cancellationToken));
            case "system scan":
            {
                var result = await services.Locations.ScanAsync(services.Preview, request.IncludeProjects, request.Budget, cancellationToken);
                return new(new
                {
                    scans = result.Scans.Select(scan => new { scan_id = scan.Id, workspace_id = scan.WorkspaceId, candidate_count = scan.Candidates.Length,
                        state = scan.Scan.IsComplete && scan.AnalysisIssues.IsEmpty ? "complete" : "partial", preview_only = false }),
                    result.Issues, result.State, execution_available = CliServices.MutationAvailable
                }, result.State == "complete" ? "success" : "partial", result.State == "complete" ? 0 : 6);
            }
            case "plan create":
            {
                var plan = await services.Cleanup.CreatePlanAsync(request.Required("scan-id"), request.All("candidate"), request.Action, cancellationToken);
                return new(plan, NextActions: [new { command = "plan show", arguments = new { plan_id = plan.Id } }]);
            }
            case "plan execute":
            {
                if (!CliServices.MutationAvailable) throw new ShouException("unsupported_capability", "Cleanup execution requires a matching native Windows 11 process. Read the plan and history; no targets were changed.");
                var cleanup = services.Cleanup;
                var consent = await cleanup.ConfirmAsync(request.Required("plan-id"), new TerminalCleanupConfirmation(WindowsConsolePrompt.ReadAsync, locale), cancellationToken);
                var execution = await cleanup.ExecuteAsync(request.Required("plan-id"), consent, cancellationToken: cancellationToken);
                return new(execution, execution.State == CleanupExecutionState.Completed ? "success" : execution.State == CleanupExecutionState.Cancelled ? "cancelled" : "partial",
                    execution.State == CleanupExecutionState.Completed ? 0 : execution.State == CleanupExecutionState.Cancelled ? 130 : 6,
                    [new { command = "history show", arguments = new { execution_id = execution.Id } }]);
            }
            case "plan show": return new(await services.History.PlanAsync(request.Required("plan-id"), cancellationToken));
            case "history list":
            {
                var page = await services.History.ListAsync(request.PageLimit, request.Optional("cursor"), cancellationToken);
                return new(page, page.State == "complete" ? "success" : "partial", page.State == "complete" ? 0 : 6);
            }
            case "history show": return new(await services.History.ShowAsync(request.Required("execution-id"), cancellationToken));
            case "history inspect":
            {
                var result = await services.History.InspectAsync(request.Required("execution-id"), request.Budget with { MaxDepth = 64 }, cancellationToken);
                return new(result, result.State == "complete" ? "success" : "partial", result.State == "complete" ? 0 : 6);
            }
            case "workspaces list": return new((await configuration.ReadAsync(cancellationToken)).Workspaces);
            case "workspaces show":
            {
                var workspace = await configuration.WorkspaceAsync(request.Required("workspace"), cancellationToken);
                return new(new { workspace, accessible = await configuration.IsAccessibleAsync(workspace, cancellationToken) });
            }
            case "workspaces add": return new(await configuration.AddWorkspaceAsync(request.Path!, request.Required("root-ref"), cancellationToken));
            case "workspaces remove":
                await configuration.RemoveWorkspaceAsync(request.Required("workspace"), cancellationToken);
                return new(new { workspace_id = request.Required("workspace"), removed = true, targets_changed = false });
            case "workspaces exclude add":
            case "workspaces exclude remove":
                return new(await configuration.SetExclusionAsync(request.Required("workspace"), request.Required("pattern"), request.Command.EndsWith("remove", StringComparison.Ordinal), request.Optional("project"), cancellationToken));
            case "exclusions list": return new(await configuration.ExclusionsAsync(request.Optional("workspace"), cancellationToken));
            case "exclusions global add":
            case "exclusions global remove":
                return new(await configuration.SetExclusionAsync(null, request.Required("pattern"), request.Command.EndsWith("remove", StringComparison.Ordinal), cancellationToken: cancellationToken));
            case "rules import": return new(await configuration.ImportRuleAsync(await CliServices.ReadRuleAsync(request.Required("file"), cancellationToken), cancellationToken));
            case "rules list":
            {
                var current = await configuration.ReadAsync(cancellationToken);
                return new(new { rules = current.Rules, bindings = current.Bindings, builtin_templates_available = true });
            }
            case "rules show":
            case "rules export": return new((await configuration.RuleAsync(request.Required("rule-id"), request.Optional("version"), cancellationToken)).Rule);
            case "rules enable":
            case "rules disable": return new(await configuration.SetRuleAsync(request.Required("workspace"), request.Required("rule-id"), request.Command.EndsWith("enable", StringComparison.Ordinal), request.Optional("version"), cancellationToken));
            case "scan":
            case "rules preview":
            {
                var preview = request.Command == "scan"
                    ? await services.Preview.ScanAsync(request.Required("workspace"), request.Budget, cancellationToken)
                    : await services.Preview.PreviewAsync(request.Required("workspace"), await CliServices.ReadRuleAsync(request.Required("file"), cancellationToken), request.Budget, cancellationToken);
                var complete = preview.Scan.IsComplete && preview.AnalysisIssues.Length == 0;
                return new(new
                {
                    scan_id = preview.Id, workspace_id = preview.WorkspaceId, preview_only = preview.PreviewOnly,
                    rules = preview.Rules.Select(rule => new { rule_id = rule.Definition.GetProperty("id"), digest = rule.Digest }), configuration_revision = preview.ConfigurationRevision,
                    state = complete ? "complete" : "partial", tree_complete = preview.Scan.IsComplete,
                    measured_entries = preview.Scan.Entries.Length, candidate_count = preview.Candidates.Length,
                    issues = preview.Scan.Issues.AddRange(preview.AnalysisIssues), execution_available = !preview.PreviewOnly && CliServices.MutationAvailable
                }, complete ? "success" : "partial", complete ? 0 : 6,
                    [new { command = "scan results", arguments = new { scan_id = preview.Id } }]);
            }
            case "scan results":
            {
                var page = await services.Preview.ResultsAsync(request.Required("scan-id"), request.PageLimit, request.Optional("cursor"), cancellationToken);
                return new(page with { ExecutionAvailable = !page.PreviewOnly && CliServices.MutationAvailable }, page.State == "complete" ? "success" : "partial", page.State == "complete" ? 0 : 6);
            }
            default: throw new ShouException("invalid_argument", "This command is unavailable.");
        }
    }
}
